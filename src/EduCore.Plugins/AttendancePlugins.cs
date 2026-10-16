using System;
using System.Collections.Generic;
using Microsoft.Xrm.Sdk;

namespace EduCore.Plugins
{
    /// <summary>
    /// Pre-operation, create and update on edu_attendance (pre-image "pre"). Validates daily against period records,
    /// derives the term from the date, defaults Recorded By to the current user's staff record and fills edu_uniquekey.
    /// </summary>
    public sealed class AttendancePlugin : PluginBase
    {
        public AttendancePlugin() : base(typeof(AttendancePlugin)) { }

        protected override void ExecuteDataversePlugin(ILocalPluginContext ctx)
        {
            var context = ctx.PluginExecutionContext;
            var target = context.InputParameters.Contains("Target") ? context.InputParameters["Target"] as Entity : null;
            if (target == null) return;
            Entity pre = context.PreEntityImages.Contains("pre") ? context.PreEntityImages["pre"] : null;
            var row = ReferenceRules.Merge(target, pre);
            var data = new OrgDataAccess(ctx.InitiatingUserService);

            var type = row.GetAttributeValue<OptionSetValue>("edu_attendancetype");
            var student = row.GetAttributeValue<EntityReference>("edu_student");
            var date = row.GetAttributeValue<DateTime?>("edu_date");
            if (type == null || student == null || !date.HasValue) return;
            var assignment = row.GetAttributeValue<EntityReference>("edu_subjectassignment");

            string error = AttendanceRules.ValidateRecord(type.Value, assignment != null);
            if (error != null) throw new InvalidPluginExecutionException(error);

            var terms = new List<TermInfo>();
            foreach (var t in data.FindAll("edu_term", new[] { "edu_startdate", "edu_enddate" }))
                terms.Add(new TermInfo(t.Id, t.GetAttributeValue<DateTime>("edu_startdate"), t.GetAttributeValue<DateTime>("edu_enddate")));
            Guid? term = AttendanceRules.TermFor(date.Value, terms);
            if (term.HasValue) target["edu_term"] = new EntityReference("edu_term", term.Value);

            if (row.GetAttributeValue<EntityReference>("edu_recordedby") == null)
            {
                var staff = data.FindFirst("edu_staff", new string[0], null, Tuple.Create<string, object>("edu_useraccount", context.InitiatingUserId));
                if (staff != null) target["edu_recordedby"] = new EntityReference("edu_staff", staff.Id);
            }
            target["edu_uniquekey"] = AttendanceRules.Key(student, date.Value, type.Value, assignment);
        }
    }

    /// <summary>
    /// Custom API <c>edu_RefreshAttendanceSummary</c> (TermId, optional AsOf; returns Refreshed). Recomputes the summary row for
    /// every student with an Active enrolment in the term's academic year, upserting by student and term. Called by a scheduled
    /// flow (nightly) or on demand.
    /// </summary>
    public sealed class RefreshAttendanceSummaryPlugin : PluginBase
    {
        public RefreshAttendanceSummaryPlugin() : base(typeof(RefreshAttendanceSummaryPlugin)) { }

        protected override void ExecuteDataversePlugin(ILocalPluginContext ctx)
        {
            var context = ctx.PluginExecutionContext;
            var termRef = (EntityReference)context.InputParameters["TermId"];
            DateTime asOf = ApiInput.OptionalDate(context.InputParameters.Contains("AsOf") ? context.InputParameters["AsOf"] : null) ?? DateTime.UtcNow;
            var service = ctx.InitiatingUserService;
            var data = new OrgDataAccess(service);

            var term = data.Retrieve("edu_term", termRef.Id, "edu_startdate", "edu_enddate", "edu_academicyear");
            if (term == null) throw new InvalidPluginExecutionException("The term was not found.");
            var year = term.GetAttributeValue<EntityReference>("edu_academicyear");

            var closed = new List<DateTime>();
            foreach (var day in data.FindAll("edu_calendarday", new[] { "edu_date" }, Tuple.Create<string, object>("edu_academicyear", year.Id)))
                closed.Add(day.GetAttributeValue<DateTime>("edu_date"));
            int teachingDays = AttendanceRules.TeachingDays(term.GetAttributeValue<DateTime>("edu_startdate"), term.GetAttributeValue<DateTime>("edu_enddate"), asOf, closed);

            var counts = new Dictionary<Guid, AttendanceCounts>();
            foreach (var e in data.FindAll("edu_enrolment", new[] { "edu_student" }, Tuple.Create<string, object>("edu_academicyear", year.Id), Tuple.Create<string, object>("statecode", 0)))
                counts[e.GetAttributeValue<EntityReference>("edu_student").Id] = new AttendanceCounts();
            foreach (var a in data.FindAll(AttendanceRules.Attendance, new[] { "edu_student", "edu_attendancestatus" },
                Tuple.Create<string, object>("edu_term", termRef.Id), Tuple.Create<string, object>("edu_attendancetype", AttendanceRules.Daily)))
            {
                Guid sid = a.GetAttributeValue<EntityReference>("edu_student").Id;
                AttendanceCounts c;
                if (!counts.TryGetValue(sid, out c)) counts[sid] = c = new AttendanceCounts();
                AttendanceRules.Count(c, a.GetAttributeValue<OptionSetValue>("edu_attendancestatus").Value);
            }

            int refreshed = 0;
            foreach (var kv in counts)
            {
                var studentRef = new EntityReference("edu_student", kv.Key);
                var row = new Entity(AttendanceRules.Summary);
                row["edu_student"] = studentRef;
                row["edu_term"] = termRef;
                row["edu_teachingdays"] = teachingDays;
                row["edu_present"] = kv.Value.Present;
                row["edu_late"] = kv.Value.Late;
                row["edu_absent"] = kv.Value.Absent;
                row["edu_excused"] = kv.Value.Excused;
                row["edu_percentage"] = AttendanceRules.Percentage(kv.Value, teachingDays);
                row["edu_refreshedon"] = DateTime.UtcNow;
                row["edu_uniquekey"] = EduKey.Build(studentRef, termRef);
                var existing = data.FindFirst(AttendanceRules.Summary, new string[0], null, Tuple.Create<string, object>("edu_student", kv.Key), Tuple.Create<string, object>("edu_term", termRef.Id));
                if (existing == null) { row["edu_name"] = "Attendance summary"; service.Create(row); }
                else { row.Id = existing.Id; service.Update(row); }
                refreshed++;
            }
            context.OutputParameters["Refreshed"] = refreshed;
        }
    }
}

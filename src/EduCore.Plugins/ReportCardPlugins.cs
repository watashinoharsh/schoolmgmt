using System;
using System.Collections.Generic;
using Microsoft.Xrm.Sdk;

namespace EduCore.Plugins
{
    /// <summary>
    /// Pre-operation on edu_reportcard update and delete (pre-image "pre"). A Published card is immutable. Moving Draft to Published
    /// stamps Published On and needs a generated card (an overall percent).
    /// </summary>
    public sealed class ReportCardGuardPlugin : PluginBase
    {
        public ReportCardGuardPlugin() : base(typeof(ReportCardGuardPlugin)) { }

        protected override void ExecuteDataversePlugin(ILocalPluginContext ctx)
        {
            var context = ctx.PluginExecutionContext;
            Entity pre = context.PreEntityImages.Contains("pre") ? context.PreEntityImages["pre"] : null;
            if (pre == null) return;
            var oldStatus = pre.GetAttributeValue<OptionSetValue>("edu_reportstatus");
            bool isDelete = context.MessageName == "Delete";
            var target = context.InputParameters.Contains("Target") ? context.InputParameters["Target"] as Entity : null;
            var newStatus = target == null ? null : target.GetAttributeValue<OptionSetValue>("edu_reportstatus");

            string error = ReportCardRules.ValidateCardChange(oldStatus == null ? (int?)null : oldStatus.Value, newStatus == null ? (int?)null : newStatus.Value, isDelete);
            if (error != null) throw new InvalidPluginExecutionException(error);

            if (!isDelete && newStatus != null && newStatus.Value == ReportCardRules.Published)
            {
                if (ReferenceRules.Merged<decimal?>(target, pre, "edu_overallpercent") == null)
                    throw new InvalidPluginExecutionException("Generate the report card before publishing it.");
                target["edu_publishedon"] = DateTime.UtcNow;
            }
        }
    }

    /// <summary>
    /// Pre-operation on edu_reportcardline create, update and delete (pre-image "pre"). Lines are fixed once their card is Published.
    /// </summary>
    public sealed class ReportCardLineGuardPlugin : PluginBase
    {
        public ReportCardLineGuardPlugin() : base(typeof(ReportCardLineGuardPlugin)) { }

        protected override void ExecuteDataversePlugin(ILocalPluginContext ctx)
        {
            var context = ctx.PluginExecutionContext;
            Entity pre = context.PreEntityImages.Contains("pre") ? context.PreEntityImages["pre"] : null;
            var target = context.InputParameters.Contains("Target") ? context.InputParameters["Target"] as Entity : null;
            var card = context.MessageName == "Delete"
                ? (pre == null ? null : pre.GetAttributeValue<EntityReference>("edu_reportcard"))
                : (target == null ? null : ReferenceRules.Merged<EntityReference>(target, pre, "edu_reportcard"));
            if (card == null) return;
            var row = new OrgDataAccess(ctx.InitiatingUserService).Retrieve(ReportCardRules.ReportCard, card.Id, "edu_reportstatus");
            if (row == null) return; // the card itself is being deleted
            var status = row.GetAttributeValue<OptionSetValue>("edu_reportstatus");
            string error = ReportCardRules.ValidateLineChange(status == null ? (int?)null : status.Value);
            if (error != null) throw new InvalidPluginExecutionException(error);
        }
    }

    /// <summary>
    /// Custom API <c>edu_GenerateReportCards</c> (TermId, SectionId; returns Generated and Skipped). For every student with an Active
    /// enrolment in the section it writes one Draft report card per student and term with one line per subject assignment, from the
    /// weighted marks. Re-running refreshes Draft cards (lines are rebuilt); Published cards are skipped.
    /// </summary>
    public sealed class GenerateReportCardsPlugin : PluginBase
    {
        public GenerateReportCardsPlugin() : base(typeof(GenerateReportCardsPlugin)) { }

        protected override void ExecuteDataversePlugin(ILocalPluginContext ctx)
        {
            var context = ctx.PluginExecutionContext;
            var termRef = (EntityReference)context.InputParameters["TermId"];
            var sectionRef = (EntityReference)context.InputParameters["SectionId"];
            var service = ctx.InitiatingUserService;
            var data = new OrgDataAccess(service);

            var term = data.Retrieve("edu_term", termRef.Id, "edu_academicyear");
            if (term == null) throw new InvalidPluginExecutionException("The term was not found.");
            var year = term.GetAttributeValue<EntityReference>("edu_academicyear");

            var bands = new List<GradeBandInfo>();
            foreach (var b in data.FindAll("edu_gradeband", new[] { "edu_minpercent", "edu_letter" }))
                bands.Add(new GradeBandInfo(b.GetAttributeValue<decimal?>("edu_minpercent") ?? 0m, b.GetAttributeValue<string>("edu_letter")));

            var assignments = data.FindAll(AcademicsRules.SubjectAssignment, new[] { "edu_course" },
                Tuple.Create<string, object>("edu_section", sectionRef.Id), Tuple.Create<string, object>("edu_term", termRef.Id));
            var weightsByAssignment = new Dictionary<Guid, Dictionary<Guid, decimal>>(); // assignment -> assessment -> weightage
            foreach (var a in assignments)
            {
                var map = new Dictionary<Guid, decimal>();
                foreach (var s in data.FindAll(AcademicsRules.Assessment, new[] { "edu_weightage" }, Tuple.Create<string, object>("edu_subjectassignment", a.Id)))
                    map[s.Id] = s.GetAttributeValue<decimal?>("edu_weightage") ?? 0m;
                weightsByAssignment[a.Id] = map;
            }

            int generated = 0, skipped = 0;
            foreach (var e in data.FindAll("edu_enrolment", new[] { "edu_student" },
                Tuple.Create<string, object>("edu_section", sectionRef.Id), Tuple.Create<string, object>("edu_academicyear", year.Id), Tuple.Create<string, object>("statecode", 0)))
            {
                var studentRef = e.GetAttributeValue<EntityReference>("edu_student");
                string key = ReportCardRules.Key(studentRef, termRef);
                var card = data.FindFirst(ReportCardRules.ReportCard, new[] { "edu_reportstatus" }, null, Tuple.Create<string, object>("edu_uniquekey", key));
                if (card != null && card.GetAttributeValue<OptionSetValue>("edu_reportstatus").Value == ReportCardRules.Published) { skipped++; continue; }

                var marks = data.FindAll(AcademicsRules.StudentMark, new[] { "edu_assessment", "edu_percentage" }, Tuple.Create<string, object>("edu_student", studentRef.Id));
                var lineRows = new List<Entity>();
                var subjectPercents = new List<decimal?>();
                foreach (var a in assignments)
                {
                    var graded = new List<WeightedMark>();
                    var weights = weightsByAssignment[a.Id];
                    foreach (var m in marks)
                    {
                        var assessment = m.GetAttributeValue<EntityReference>("edu_assessment");
                        var pct = m.GetAttributeValue<decimal?>("edu_percentage");
                        decimal w;
                        if (assessment != null && pct.HasValue && weights.TryGetValue(assessment.Id, out w)) graded.Add(new WeightedMark(pct.Value, w));
                    }
                    decimal? subject = ReportCardRules.SubjectPercent(graded);
                    subjectPercents.Add(subject);
                    var course = a.GetAttributeValue<EntityReference>("edu_course");
                    var line = new Entity(ReportCardRules.Line);
                    line["edu_name"] = (course != null && course.Name != null) ? course.Name : "Subject";
                    line["edu_subjectassignment"] = new EntityReference(AcademicsRules.SubjectAssignment, a.Id);
                    if (subject.HasValue) { line["edu_finalpercent"] = subject.Value; line["edu_letter"] = AcademicsRules.GradeLetter(subject, bands); }
                    lineRows.Add(line);
                }
                decimal? overall = ReportCardRules.Overall(subjectPercents);

                var summary = data.FindFirst(AttendanceRules.Summary, new[] { "edu_percentage" }, null,
                    Tuple.Create<string, object>("edu_student", studentRef.Id), Tuple.Create<string, object>("edu_term", termRef.Id));

                var row = new Entity(ReportCardRules.ReportCard);
                row["edu_student"] = studentRef;
                row["edu_term"] = termRef;
                row["edu_overallpercent"] = overall;
                row["edu_overallgrade"] = AcademicsRules.GradeLetter(overall, bands);
                row["edu_attendancepercent"] = summary == null ? null : summary.GetAttributeValue<decimal?>("edu_percentage");
                row["edu_reportstatus"] = new OptionSetValue(ReportCardRules.Draft);
                row["edu_generatedon"] = DateTime.UtcNow;
                row["edu_uniquekey"] = key;

                Guid cardId;
                if (card == null) { row["edu_name"] = "Report card"; cardId = service.Create(row); }
                else
                {
                    row.Id = cardId = card.Id;
                    service.Update(row);
                    foreach (var old in data.FindAll(ReportCardRules.Line, new string[0], Tuple.Create<string, object>("edu_reportcard", cardId))) service.Delete(ReportCardRules.Line, old.Id);
                }
                var cardRef = new EntityReference(ReportCardRules.ReportCard, cardId);
                foreach (var line in lineRows)
                {
                    line["edu_reportcard"] = cardRef;
                    line["edu_uniquekey"] = ReportCardRules.LineKey(cardRef, line.GetAttributeValue<EntityReference>("edu_subjectassignment"));
                    service.Create(line);
                }
                generated++;
            }
            context.OutputParameters["Generated"] = generated;
            context.OutputParameters["Skipped"] = skipped;
        }
    }
}

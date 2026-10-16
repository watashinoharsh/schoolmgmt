using System;
using Microsoft.Xrm.Sdk;

namespace EduCore.Plugins
{
    /// <summary>
    /// Pre-operation, create and update on edu_applicant (pre-image "pre" on update, filtering attribute statuscode
    /// and edu_decisionreason). Enforces the status machine, the Enrolled integrity check and the Rejected reason.
    /// </summary>
    public sealed class ApplicantPlugin : PluginBase
    {
        public ApplicantPlugin() : base(typeof(ApplicantPlugin)) { }

        protected override void ExecuteDataversePlugin(ILocalPluginContext ctx)
        {
            var context = ctx.PluginExecutionContext;
            var target = context.InputParameters.Contains("Target") ? context.InputParameters["Target"] as Entity : null;
            if (target == null) return;
            Entity pre = context.PreEntityImages.Contains("pre") ? context.PreEntityImages["pre"] : null;
            var row = ReferenceRules.Merge(target, pre);

            var newStatus = row.GetAttributeValue<OptionSetValue>("statuscode");
            if (newStatus == null) return;
            var oldStatus = pre == null ? null : pre.GetAttributeValue<OptionSetValue>("statuscode");
            int? from = oldStatus == null ? (int?)null : oldStatus.Value;

            string error = AdmissionsRules.ValidateTransition(from, newStatus.Value);
            if (error == null) error = AdmissionsRules.ValidateRejected(newStatus.Value, row.GetAttributeValue<string>("edu_decisionreason"));
            if (error == null && newStatus.Value == AdmissionsRules.Enrolled && from != AdmissionsRules.Enrolled)
            {
                bool exists = new OrgDataAccess(ctx.InitiatingUserService).Exists(PeopleRules.Student, "edu_sourceapplicant", target.Id);
                error = AdmissionsRules.ValidateEnrolled(newStatus.Value, exists);
            }
            if (error != null) throw new InvalidPluginExecutionException(error);
        }
    }

    /// <summary>
    /// Implementation of the Custom API <c>edu_EnrolApplicant</c> (ApplicantId, SectionId, optional StartDate and Relationship;
    /// returns StudentId and Created). Creates the student, the primary guardian link and the enrolment, and marks the applicant
    /// Enrolled, all inside the API's transaction so a failure leaves nothing behind. Idempotent: an applicant that already has a
    /// student returns it.
    /// </summary>
    public sealed class EnrolApplicantPlugin : PluginBase
    {
        private const int LegalGuardian = 859680002;

        public EnrolApplicantPlugin() : base(typeof(EnrolApplicantPlugin)) { }

        protected override void ExecuteDataversePlugin(ILocalPluginContext ctx)
        {
            var context = ctx.PluginExecutionContext;
            var applicantRef = (EntityReference)context.InputParameters["ApplicantId"];
            var sectionRef = (EntityReference)context.InputParameters["SectionId"];
            DateTime start = ApiInput.OptionalDate(context.InputParameters.Contains("StartDate") ? context.InputParameters["StartDate"] : null) ?? DateTime.UtcNow;
            int relationship = ApiInput.OptionalChoice(context.InputParameters.Contains("Relationship") ? context.InputParameters["Relationship"] : null) ?? LegalGuardian;

            var service = ctx.InitiatingUserService;
            var data = new OrgDataAccess(service);

            var applicant = data.Retrieve(AdmissionsRules.Applicant, applicantRef.Id, "edu_name", "edu_dateofbirth", "edu_academicyear", "edu_applyinggrade", "edu_primaryguardian", "statuscode");
            if (applicant == null) throw new InvalidPluginExecutionException("The applicant was not found.");
            int status = applicant.GetAttributeValue<OptionSetValue>("statuscode").Value;

            var existing = data.FindFirst(PeopleRules.Student, new string[0], null, Tuple.Create<string, object>("edu_sourceapplicant", applicantRef.Id));
            if (existing != null)
            {
                if (status != AdmissionsRules.Enrolled) service.Update(AdmissionsRules.MarkEnrolled(applicantRef.Id));
                Respond(context, existing.Id, false);
                return;
            }

            var section = data.Retrieve(PeopleRules.Section, sectionRef.Id, "edu_academicyear", "edu_grade");
            if (section == null) throw new InvalidPluginExecutionException("The section was not found.");
            string error = AdmissionsRules.ValidateEnrol(status, applicant.GetAttributeValue<EntityReference>("edu_academicyear"), applicant.GetAttributeValue<EntityReference>("edu_applyinggrade"),
                section.GetAttributeValue<EntityReference>("edu_academicyear"), section.GetAttributeValue<EntityReference>("edu_grade"));
            if (error != null) throw new InvalidPluginExecutionException(error);

            var student = AdmissionsRules.BuildStudent(applicant, start);
            service.Create(student);
            var studentRef = new EntityReference(PeopleRules.Student, student.Id);

            var guardian = applicant.GetAttributeValue<EntityReference>("edu_primaryguardian");
            if (guardian != null) service.Create(AdmissionsRules.BuildGuardianLink(studentRef, guardian, relationship));
            service.Create(AdmissionsRules.BuildEnrolment(studentRef, sectionRef, section.GetAttributeValue<EntityReference>("edu_academicyear"), start, student.GetAttributeValue<string>("edu_name")));
            service.Update(AdmissionsRules.MarkEnrolled(applicantRef.Id));

            Respond(context, student.Id, true);
        }

        private static void Respond(IPluginExecutionContext context, Guid studentId, bool created)
        {
            context.OutputParameters["StudentId"] = new EntityReference(PeopleRules.Student, studentId);
            context.OutputParameters["Created"] = created;
        }
    }
}

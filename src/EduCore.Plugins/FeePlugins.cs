using System;
using System.Collections.Generic;
using Microsoft.Xrm.Sdk;

namespace EduCore.Plugins
{
    internal static class InvoiceTotals
    {
        /// <summary>Recomputes total, paid and status from the invoice's lines and payments, writing only what changed.</summary>
        public static void Recalculate(IOrganizationService service, IDataAccess data, Guid invoiceId)
        {
            var invoice = data.Retrieve(FeeRules.Invoice, invoiceId, "edu_totalamount", "edu_paidamount", "edu_dueamount", "edu_invoicestatus", "edu_duedate");
            if (invoice == null) return; // the invoice itself is being deleted

            var lines = new List<KeyValuePair<decimal, decimal>>();
            foreach (var l in data.FindAll(FeeRules.Line, new[] { "edu_quantity", "edu_amount" }, Tuple.Create<string, object>("edu_invoice", invoiceId)))
                lines.Add(new KeyValuePair<decimal, decimal>(l.GetAttributeValue<decimal?>("edu_quantity") ?? 1m, l.GetAttributeValue<decimal?>("edu_amount") ?? 0m));
            var payments = new List<KeyValuePair<int, decimal>>();
            foreach (var p in data.FindAll(FeeRules.Payment, new[] { "edu_amount", "edu_paymentstatus" }, Tuple.Create<string, object>("edu_invoice", invoiceId)))
                payments.Add(new KeyValuePair<int, decimal>(p.GetAttributeValue<OptionSetValue>("edu_paymentstatus").Value, p.GetAttributeValue<decimal?>("edu_amount") ?? 0m));

            decimal total = FeeRules.Total(lines);
            decimal paid = FeeRules.SumPaid(payments);
            int current = invoice.GetAttributeValue<OptionSetValue>("edu_invoicestatus").Value;
            int status = FeeRules.StatusFor(current, total, paid, invoice.GetAttributeValue<DateTime?>("edu_duedate"), DateTime.UtcNow);

            if (invoice.GetAttributeValue<decimal?>("edu_totalamount") == total
                && invoice.GetAttributeValue<decimal?>("edu_paidamount") == paid
                && invoice.GetAttributeValue<decimal?>("edu_dueamount") == FeeRules.Due(total, paid)
                && current == status) return;

            var update = new Entity(FeeRules.Invoice, invoiceId);
            update["edu_totalamount"] = total;
            update["edu_paidamount"] = paid;
            update["edu_dueamount"] = FeeRules.Due(total, paid);
            update["edu_invoicestatus"] = new OptionSetValue(status);
            service.Update(update);
        }
    }

    /// <summary>
    /// Pre-operation on edu_invoiceline create, update and delete (pre-image "pre"). Blocks changes unless the invoice is a draft
    /// and keeps a line on its invoice.
    /// </summary>
    public sealed class InvoiceLineGuardPlugin : PluginBase
    {
        public InvoiceLineGuardPlugin() : base(typeof(InvoiceLineGuardPlugin)) { }

        protected override void ExecuteDataversePlugin(ILocalPluginContext ctx)
        {
            var context = ctx.PluginExecutionContext;
            var data = new OrgDataAccess(ctx.InitiatingUserService);
            Entity pre = context.PreEntityImages.Contains("pre") ? context.PreEntityImages["pre"] : null;
            var target = context.InputParameters.Contains("Target") ? context.InputParameters["Target"] as Entity : null;

            EntityReference invoice;
            if (context.MessageName == "Delete") invoice = pre == null ? null : pre.GetAttributeValue<EntityReference>("edu_invoice");
            else
            {
                if (target == null) return;
                invoice = ReferenceRules.Merged<EntityReference>(target, pre, "edu_invoice");
                if (context.MessageName == "Update" && pre != null && target.Contains("edu_invoice"))
                {
                    var before = pre.GetAttributeValue<EntityReference>("edu_invoice");
                    if (before != null && invoice != null && before.Id != invoice.Id)
                        throw new InvalidPluginExecutionException("An invoice line cannot be moved to another invoice.");
                }
            }
            if (invoice == null) return;
            var row = data.Retrieve(FeeRules.Invoice, invoice.Id, "edu_invoicestatus");
            if (row == null) return;
            string error = FeeRules.ValidateLineEdit(row.GetAttributeValue<OptionSetValue>("edu_invoicestatus").Value);
            if (error != null) throw new InvalidPluginExecutionException(error);
        }
    }

    /// <summary>
    /// Pre-operation on edu_payment create, update and delete (pre-image "pre"). Payments are reversed, never deleted; a cleared
    /// payment cannot exceed what is due and a draft invoice takes no payment. Fills Recorded By from the current user's staff record.
    /// </summary>
    public sealed class PaymentGuardPlugin : PluginBase
    {
        public PaymentGuardPlugin() : base(typeof(PaymentGuardPlugin)) { }

        protected override void ExecuteDataversePlugin(ILocalPluginContext ctx)
        {
            var context = ctx.PluginExecutionContext;
            if (context.MessageName == "Delete")
                throw new InvalidPluginExecutionException("Payments cannot be deleted. Reverse the payment instead.");

            var target = context.InputParameters.Contains("Target") ? context.InputParameters["Target"] as Entity : null;
            if (target == null) return;
            Entity pre = context.PreEntityImages.Contains("pre") ? context.PreEntityImages["pre"] : null;
            var row = ReferenceRules.Merge(target, pre);
            var data = new OrgDataAccess(ctx.InitiatingUserService);

            var invoiceRef = row.GetAttributeValue<EntityReference>("edu_invoice");
            var amount = row.GetAttributeValue<decimal?>("edu_amount");
            var status = row.GetAttributeValue<OptionSetValue>("edu_paymentstatus");
            if (invoiceRef == null || !amount.HasValue || status == null) return;

            if (context.MessageName == "Update" && pre != null)
            {
                // A reversed payment is history: only its status may not change back.
                var was = pre.GetAttributeValue<OptionSetValue>("edu_paymentstatus");
                if (was != null && was.Value == FeeRules.Reversed && status.Value != FeeRules.Reversed)
                    throw new InvalidPluginExecutionException("A reversed payment cannot be reinstated. Record a new payment.");
                var oldAmount = pre.GetAttributeValue<decimal?>("edu_amount");
                if (was != null && was.Value == FeeRules.Reversed && oldAmount != amount)
                    throw new InvalidPluginExecutionException("A reversed payment cannot be changed.");
            }

            var invoice = data.Retrieve(FeeRules.Invoice, invoiceRef.Id, "edu_totalamount", "edu_invoicestatus");
            if (invoice == null) throw new InvalidPluginExecutionException("The invoice was not found.");
            decimal total = invoice.GetAttributeValue<decimal?>("edu_totalamount") ?? 0m;
            var others = new List<KeyValuePair<int, decimal>>();
            foreach (var p in data.FindAll(FeeRules.Payment, new[] { "edu_amount", "edu_paymentstatus" }, Tuple.Create<string, object>("edu_invoice", invoiceRef.Id)))
                if (p.Id != target.Id) others.Add(new KeyValuePair<int, decimal>(p.GetAttributeValue<OptionSetValue>("edu_paymentstatus").Value, p.GetAttributeValue<decimal?>("edu_amount") ?? 0m));
            decimal due = FeeRules.Due(total, FeeRules.SumPaid(others));

            string error = FeeRules.ValidatePayment(amount.Value, invoice.GetAttributeValue<OptionSetValue>("edu_invoicestatus").Value, due, status.Value);
            if (error != null) throw new InvalidPluginExecutionException(error);

            if (row.GetAttributeValue<EntityReference>("edu_recordedby") == null)
            {
                var staff = data.FindFirst("edu_staff", new string[0], null, Tuple.Create<string, object>("edu_useraccount", context.InitiatingUserId));
                if (staff != null) target["edu_recordedby"] = new EntityReference("edu_staff", staff.Id);
            }
        }
    }

    /// <summary>
    /// Post-operation on edu_invoiceline and edu_payment create, update and delete (pre-image "pre", post-image "post" where present).
    /// Stored totals are maintained in the same transaction because money cannot tolerate eventual consistency.
    /// </summary>
    public sealed class InvoiceTotalsPlugin : PluginBase
    {
        public InvoiceTotalsPlugin() : base(typeof(InvoiceTotalsPlugin)) { }

        protected override void ExecuteDataversePlugin(ILocalPluginContext ctx)
        {
            var context = ctx.PluginExecutionContext;
            var ids = new HashSet<Guid>();
            Entity pre = context.PreEntityImages.Contains("pre") ? context.PreEntityImages["pre"] : null;
            Entity post = context.PostEntityImages.Contains("post") ? context.PostEntityImages["post"] : null;
            var target = context.InputParameters.Contains("Target") ? context.InputParameters["Target"] as Entity : null;
            foreach (var source in new[] { pre, post, target })
            {
                var r = source == null ? null : source.GetAttributeValue<EntityReference>("edu_invoice");
                if (r != null) ids.Add(r.Id);
            }
            var data = new OrgDataAccess(ctx.InitiatingUserService);
            foreach (var id in ids) InvoiceTotals.Recalculate(ctx.InitiatingUserService, data, id);
        }
    }

    /// <summary>Pre-operation, create and update on edu_feestructure (pre-image "pre"). Fills edu_uniquekey from grade, term and fee type.</summary>
    public sealed class FeeStructurePlugin : PluginBase
    {
        public FeeStructurePlugin() : base(typeof(FeeStructurePlugin)) { }

        protected override void ExecuteDataversePlugin(ILocalPluginContext ctx)
        {
            var context = ctx.PluginExecutionContext;
            var target = context.InputParameters.Contains("Target") ? context.InputParameters["Target"] as Entity : null;
            if (target == null) return;
            Entity pre = context.PreEntityImages.Contains("pre") ? context.PreEntityImages["pre"] : null;
            var row = ReferenceRules.Merge(target, pre);
            var grade = row.GetAttributeValue<EntityReference>("edu_grade");
            var term = row.GetAttributeValue<EntityReference>("edu_term");
            var type = row.GetAttributeValue<OptionSetValue>("edu_feetype");
            if (grade == null || term == null || type == null) return;
            var amount = row.GetAttributeValue<decimal?>("edu_amount");
            if (amount.HasValue && amount.Value < 0m) throw new InvalidPluginExecutionException("A fee amount cannot be negative.");
            target["edu_uniquekey"] = FeeRules.FeeStructureKey(grade, term, type);
        }
    }

    /// <summary>
    /// Custom API <c>edu_GenerateInvoice</c> (StudentId, TermId, optional DueDate; returns InvoiceId and Created). Builds one Draft
    /// invoice with its lines from the fee structure for the student's current grade and term, reduced by the student's fee concession.
    /// Idempotent: an existing invoice for the student and term is returned unchanged.
    /// </summary>
    public sealed class GenerateInvoicePlugin : PluginBase
    {
        public GenerateInvoicePlugin() : base(typeof(GenerateInvoicePlugin)) { }

        protected override void ExecuteDataversePlugin(ILocalPluginContext ctx)
        {
            var context = ctx.PluginExecutionContext;
            var studentRef = (EntityReference)context.InputParameters["StudentId"];
            var termRef = (EntityReference)context.InputParameters["TermId"];
            DateTime? dueDate = context.InputParameters.Contains("DueDate") ? context.InputParameters["DueDate"] as DateTime? : null;
            var service = ctx.InitiatingUserService;
            var data = new OrgDataAccess(service);

            string key = FeeRules.InvoiceKey(studentRef, termRef);
            var existing = data.FindFirst(FeeRules.Invoice, new string[0], null, Tuple.Create<string, object>("edu_uniquekey", key));
            if (existing != null)
            {
                context.OutputParameters["InvoiceId"] = existing.Id;
                context.OutputParameters["Created"] = false;
                return;
            }

            var student = data.Retrieve("edu_student", studentRef.Id, "edu_currentgrade", "edu_feeconcessionpercent");
            if (student == null) throw new InvalidPluginExecutionException("The student was not found.");
            var grade = student.GetAttributeValue<EntityReference>("edu_currentgrade");
            if (grade == null) throw new InvalidPluginExecutionException("The student has no current grade, so there is no fee structure to bill.");
            string concessionError = FeeRules.ValidateConcession(student.GetAttributeValue<decimal?>("edu_feeconcessionpercent"));
            if (concessionError != null) throw new InvalidPluginExecutionException(concessionError);

            var items = new List<FeeItem>();
            foreach (var f in data.FindAll(FeeRules.FeeStructure, new[] { "edu_feetype", "edu_amount", "edu_name" },
                Tuple.Create<string, object>("edu_grade", grade.Id), Tuple.Create<string, object>("edu_term", termRef.Id)))
            {
                var type = f.GetAttributeValue<OptionSetValue>("edu_feetype");
                if (type == null) continue;
                items.Add(new FeeItem(type.Value, f.GetAttributeValue<string>("edu_name"), f.GetAttributeValue<decimal?>("edu_amount") ?? 0m));
            }
            var lines = FeeRules.BuildLines(items, student.GetAttributeValue<decimal?>("edu_feeconcessionpercent"));
            if (lines.Count == 0) throw new InvalidPluginExecutionException("No fee structure rows apply to this student's grade and term.");

            var invoice = new Entity(FeeRules.Invoice);
            invoice["edu_student"] = studentRef;
            invoice["edu_term"] = termRef;
            invoice["edu_invoicestatus"] = new OptionSetValue(FeeRules.Draft);
            invoice["edu_totalamount"] = 0m;
            invoice["edu_paidamount"] = 0m;
            invoice["edu_dueamount"] = 0m;
            if (dueDate.HasValue) invoice["edu_duedate"] = dueDate.Value;
            invoice["edu_uniquekey"] = key;
            Guid invoiceId = service.Create(invoice);

            foreach (var l in lines)
            {
                var line = new Entity(FeeRules.Line);
                line["edu_invoice"] = new EntityReference(FeeRules.Invoice, invoiceId);
                line["edu_feetype"] = new OptionSetValue(l.FeeType);
                line["edu_name"] = l.Description;
                line["edu_quantity"] = l.Quantity;
                line["edu_amount"] = l.Amount;
                service.Create(line); // InvoiceTotalsPlugin keeps the invoice totals current
            }

            context.OutputParameters["InvoiceId"] = invoiceId;
            context.OutputParameters["Created"] = true;
        }
    }
}

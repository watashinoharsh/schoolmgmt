using System;
using System.Collections.Generic;
using Microsoft.Xrm.Sdk;

namespace EduCore.Plugins
{
    /// <summary>Reads optional Custom API inputs. The platform can hand an omitted DateTime parameter over as 0001-01-01.</summary>
    public static class ApiInput
    {
        /// <summary>The date, or null when the parameter was left out, null, or is the 0001-01-01 placeholder.</summary>
        public static DateTime? OptionalDate(object value)
        {
            if (!(value is DateTime)) return null;
            var d = (DateTime)value;
            return d.Year <= 1 ? (DateTime?)null : d;
        }

        /// <summary>The choice value, or null when the parameter was left out: an omitted integer arrives as 0, which no choice uses.</summary>
        public static int? OptionalChoice(object value)
        {
            if (!(value is int)) return null;
            var v = (int)value;
            return v <= 0 ? (int?)null : v;
        }
    }

    /// <summary>One fee-structure row as the generator sees it.</summary>
    public sealed class FeeItem
    {
        public int FeeType { get; private set; }
        public string Description { get; private set; }
        public decimal Amount { get; private set; }
        public FeeItem(int feeType, string description, decimal amount) { FeeType = feeType; Description = description; Amount = amount; }
    }

    /// <summary>An invoice line to create: the amount is the unit amount, the line total is quantity x amount.</summary>
    public sealed class InvoiceLineDraft
    {
        public int FeeType { get; set; }
        public string Description { get; set; }
        public decimal Quantity { get; set; }
        public decimal Amount { get; set; }
    }

    /// <summary>Pure fee and invoice rules (LLD section 4 and 5). Money is rounded to two places, away from zero.</summary>
    public static class FeeRules
    {
        public const string Invoice = "edu_invoice";
        public const string Line = "edu_invoiceline";
        public const string Payment = "edu_payment";
        public const string FeeStructure = "edu_feestructure";

        // edu_invoicestatus
        public const int Draft = 859680000;
        public const int Sent = 859680001;
        public const int PartiallyPaid = 859680002;
        public const int Paid = 859680003;
        public const int Overdue = 859680004;
        // edu_paymentstatus
        public const int Cleared = 859680000;
        public const int Reversed = 859680001;

        public static decimal Round(decimal value) { return Math.Round(value, 2, MidpointRounding.AwayFromZero); }

        public static decimal LineTotal(decimal quantity, decimal amount) { return Round(quantity * amount); }

        /// <summary>Total of the lines (quantity x amount each).</summary>
        public static decimal Total(IEnumerable<KeyValuePair<decimal, decimal>> quantityAndAmount)
        {
            decimal sum = 0m;
            foreach (var l in quantityAndAmount) sum += LineTotal(l.Key, l.Value);
            return Round(sum);
        }

        /// <summary>Sum of payments; reversed payments do not count.</summary>
        public static decimal SumPaid(IEnumerable<KeyValuePair<int, decimal>> statusAndAmount)
        {
            decimal sum = 0m;
            foreach (var p in statusAndAmount) if (p.Key == Cleared) sum += p.Value;
            return Round(sum);
        }

        public static decimal Due(decimal total, decimal paid) { return Round(total - paid); }

        /// <summary>
        /// Status after a payment or line change. Draft stays Draft (it leaves Draft only when staff send it); otherwise
        /// Paid when settled, Partially Paid when something was paid, Overdue when past due and unpaid, else Sent.
        /// </summary>
        public static int StatusFor(int current, decimal total, decimal paid, DateTime? dueDate, DateTime today)
        {
            if (current == Draft) return Draft;
            if (total > 0m && paid >= total) return Paid;
            if (paid > 0m) return PartiallyPaid;
            if (dueDate.HasValue && dueDate.Value.Date < today.Date) return Overdue;
            return Sent;
        }

        /// <summary>Daily job: true for an unpaid, sent invoice whose due date has passed.</summary>
        public static bool ShouldMarkOverdue(int status, decimal due, DateTime? dueDate, DateTime today)
        {
            return (status == Sent || status == PartiallyPaid) && due > 0m && dueDate.HasValue && dueDate.Value.Date < today.Date;
        }

        /// <summary>Fee reminder: unpaid, sent or part-paid, and the due date falls within the next <paramref name="daysBefore"/> days.</summary>
        public static bool ReminderDue(int status, decimal due, DateTime? dueDate, DateTime today, int daysBefore)
        {
            if (status != Sent && status != PartiallyPaid) return false;
            if (due <= 0m || !dueDate.HasValue) return false;
            double days = (dueDate.Value.Date - today.Date).TotalDays;
            return days >= 0 && days <= daysBefore;
        }

        /// <summary>Lines can be edited only while the invoice is a draft.</summary>
        public static string ValidateLineEdit(int invoiceStatus)
        {
            return invoiceStatus == Draft ? null : "Invoice lines can only be changed while the invoice is a draft.";
        }

        /// <summary>A payment needs a positive amount, a sent invoice and must not exceed what is due.</summary>
        public static string ValidatePayment(decimal amount, int invoiceStatus, decimal invoiceDue, int paymentStatus)
        {
            if (amount <= 0m) return "A payment amount must be greater than zero.";
            if (invoiceStatus == Draft) return "Send the invoice before recording a payment.";
            if (paymentStatus == Cleared && amount > invoiceDue) return "The payment is more than the amount due on the invoice.";
            return null;
        }

        /// <summary>Concession must be 0 to 100.</summary>
        public static string ValidateConcession(decimal? percent)
        {
            return percent.HasValue && (percent.Value < 0m || percent.Value > 100m) ? "The fee concession must be between 0 and 100 percent." : null;
        }

        /// <summary>Invoice lines for a student: one per fee row, amounts reduced by the concession percent. Zero amounts are skipped.</summary>
        public static IList<InvoiceLineDraft> BuildLines(IEnumerable<FeeItem> items, decimal? concessionPercent)
        {
            decimal factor = 1m - (concessionPercent ?? 0m) / 100m;
            var lines = new List<InvoiceLineDraft>();
            foreach (var item in items)
            {
                decimal amount = Round(item.Amount * factor);
                if (amount <= 0m) continue;
                lines.Add(new InvoiceLineDraft { FeeType = item.FeeType, Description = item.Description, Quantity = 1m, Amount = amount });
            }
            return lines;
        }

        public static string InvoiceKey(EntityReference student, EntityReference term) { return EduKey.Build(student, term); }

        public static string FeeStructureKey(EntityReference grade, EntityReference term, OptionSetValue feeType) { return EduKey.Build(grade, term, feeType); }
    }
}

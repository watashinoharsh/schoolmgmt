using System;
using System.Collections.Generic;
using Microsoft.Xrm.Sdk;
using Xunit;

namespace EduCore.Plugins.Tests
{
    public class FeeRulesTests
    {
        private static readonly DateTime Today = new DateTime(2026, 10, 16);
        private static KeyValuePair<decimal, decimal> L(decimal q, decimal a) { return new KeyValuePair<decimal, decimal>(q, a); }
        private static KeyValuePair<int, decimal> P(int s, decimal a) { return new KeyValuePair<int, decimal>(s, a); }

        [Fact]
        public void Total_is_quantity_times_amount_summed_and_rounded()
        {
            Assert.Equal(0m, FeeRules.Total(new KeyValuePair<decimal, decimal>[0]));
            Assert.Equal(350.50m, FeeRules.Total(new[] { L(1, 200m), L(3, 50.1666m) }));
            Assert.Equal(0.01m, FeeRules.LineTotal(1, 0.005m));
        }

        [Fact]
        public void Reversed_payments_do_not_count_as_paid()
        {
            Assert.Equal(150m, FeeRules.SumPaid(new[] { P(FeeRules.Cleared, 100m), P(FeeRules.Reversed, 80m), P(FeeRules.Cleared, 50m) }));
            Assert.Equal(0m, FeeRules.SumPaid(new[] { P(FeeRules.Reversed, 80m) }));
        }

        [Fact]
        public void Due_is_total_minus_paid()
        {
            Assert.Equal(75.25m, FeeRules.Due(200m, 124.75m));
        }

        [Fact]
        public void Draft_stays_draft_whatever_the_money_says()
        {
            Assert.Equal(FeeRules.Draft, FeeRules.StatusFor(FeeRules.Draft, 100m, 100m, Today.AddDays(-5), Today));
        }

        [Fact]
        public void Status_follows_payments()
        {
            var future = Today.AddDays(10);
            Assert.Equal(FeeRules.Sent, FeeRules.StatusFor(FeeRules.Sent, 100m, 0m, future, Today));
            Assert.Equal(FeeRules.PartiallyPaid, FeeRules.StatusFor(FeeRules.Sent, 100m, 40m, future, Today));
            Assert.Equal(FeeRules.Paid, FeeRules.StatusFor(FeeRules.Sent, 100m, 100m, future, Today));
            Assert.Equal(FeeRules.Paid, FeeRules.StatusFor(FeeRules.Overdue, 100m, 100m, Today.AddDays(-3), Today));
        }

        [Fact]
        public void A_reversal_moves_the_status_back()
        {
            Assert.Equal(FeeRules.Sent, FeeRules.StatusFor(FeeRules.Paid, 100m, 0m, Today.AddDays(5), Today));
            Assert.Equal(FeeRules.Overdue, FeeRules.StatusFor(FeeRules.Paid, 100m, 0m, Today.AddDays(-1), Today));
        }

        [Fact]
        public void A_zero_total_is_never_paid()
        {
            Assert.Equal(FeeRules.Sent, FeeRules.StatusFor(FeeRules.Sent, 0m, 0m, null, Today));
        }

        [Fact]
        public void Overdue_marking_needs_an_unpaid_sent_invoice_past_due()
        {
            Assert.True(FeeRules.ShouldMarkOverdue(FeeRules.Sent, 50m, Today.AddDays(-1), Today));
            Assert.True(FeeRules.ShouldMarkOverdue(FeeRules.PartiallyPaid, 50m, Today.AddDays(-1), Today));
            Assert.False(FeeRules.ShouldMarkOverdue(FeeRules.Sent, 50m, Today, Today));
            Assert.False(FeeRules.ShouldMarkOverdue(FeeRules.Draft, 50m, Today.AddDays(-9), Today));
            Assert.False(FeeRules.ShouldMarkOverdue(FeeRules.Paid, 0m, Today.AddDays(-9), Today));
            Assert.False(FeeRules.ShouldMarkOverdue(FeeRules.Overdue, 50m, Today.AddDays(-9), Today));
            Assert.False(FeeRules.ShouldMarkOverdue(FeeRules.Sent, 50m, null, Today));
        }

        [Fact]
        public void Reminder_window_is_today_to_days_before_inclusive()
        {
            Assert.True(FeeRules.ReminderDue(FeeRules.Sent, 50m, Today.AddDays(7), Today, 7));
            Assert.True(FeeRules.ReminderDue(FeeRules.Sent, 50m, Today, Today, 7));
            Assert.False(FeeRules.ReminderDue(FeeRules.Sent, 50m, Today.AddDays(8), Today, 7));
            Assert.False(FeeRules.ReminderDue(FeeRules.Sent, 50m, Today.AddDays(-1), Today, 7));
            Assert.False(FeeRules.ReminderDue(FeeRules.Paid, 0m, Today.AddDays(3), Today, 7));
            Assert.False(FeeRules.ReminderDue(FeeRules.Draft, 50m, Today.AddDays(3), Today, 7));
        }

        [Fact]
        public void Lines_are_editable_only_in_draft()
        {
            Assert.Null(FeeRules.ValidateLineEdit(FeeRules.Draft));
            Assert.NotNull(FeeRules.ValidateLineEdit(FeeRules.Sent));
            Assert.NotNull(FeeRules.ValidateLineEdit(FeeRules.Paid));
        }

        [Fact]
        public void Payment_validation()
        {
            Assert.NotNull(FeeRules.ValidatePayment(0m, FeeRules.Sent, 100m, FeeRules.Cleared));
            Assert.NotNull(FeeRules.ValidatePayment(-5m, FeeRules.Sent, 100m, FeeRules.Cleared));
            Assert.NotNull(FeeRules.ValidatePayment(10m, FeeRules.Draft, 100m, FeeRules.Cleared));
            Assert.NotNull(FeeRules.ValidatePayment(100.01m, FeeRules.Sent, 100m, FeeRules.Cleared));
            Assert.Null(FeeRules.ValidatePayment(100m, FeeRules.Sent, 100m, FeeRules.Cleared));
            Assert.Null(FeeRules.ValidatePayment(30m, FeeRules.PartiallyPaid, 60m, FeeRules.Cleared));
            // A reversed row is history, so the over-payment check does not apply to it.
            Assert.Null(FeeRules.ValidatePayment(500m, FeeRules.Paid, 0m, FeeRules.Reversed));
        }

        [Fact]
        public void Concession_must_be_between_0_and_100()
        {
            Assert.Null(FeeRules.ValidateConcession(null));
            Assert.Null(FeeRules.ValidateConcession(0m));
            Assert.Null(FeeRules.ValidateConcession(100m));
            Assert.NotNull(FeeRules.ValidateConcession(-0.1m));
            Assert.NotNull(FeeRules.ValidateConcession(100.1m));
        }

        [Fact]
        public void Generated_lines_apply_the_concession_and_skip_zero_amounts()
        {
            const int tuition = 859680000, lab = 859680002, free = 859680001;
            var items = new[] { new FeeItem(tuition, "Tuition", 1000m), new FeeItem(lab, "Lab", 33.33m), new FeeItem(free, "Waived", 0m) };

            var none = FeeRules.BuildLines(items, null);
            Assert.Equal(2, none.Count);
            Assert.Equal(1000m, none[0].Amount);

            var half = FeeRules.BuildLines(items, 50m);
            Assert.Equal(500m, half[0].Amount);
            Assert.Equal(16.67m, half[1].Amount);
            Assert.Equal(1m, half[0].Quantity);

            Assert.Empty(FeeRules.BuildLines(items, 100m));
        }

        [Fact]
        public void Optional_api_dates_treat_the_placeholder_as_missing()
        {
            Assert.Null(ApiInput.OptionalDate(null));
            Assert.Null(ApiInput.OptionalDate("2026-01-01"));
            Assert.Null(ApiInput.OptionalDate(DateTime.MinValue));
            Assert.Null(ApiInput.OptionalDate(new DateTime(1, 1, 1, 5, 30, 0)));
            Assert.Equal(new DateTime(2026, 9, 30), ApiInput.OptionalDate(new DateTime(2026, 9, 30)));
        }

        [Fact]
        public void Optional_api_choices_treat_zero_as_missing()
        {
            Assert.Null(ApiInput.OptionalChoice(null));
            Assert.Null(ApiInput.OptionalChoice(0));
            Assert.Null(ApiInput.OptionalChoice("859680000"));
            Assert.Equal(859680001, ApiInput.OptionalChoice(859680001));
        }

        [Fact]
        public void Keys_use_the_shared_format()
        {
            var s = new EntityReference("edu_student", new Guid("11111111-1111-1111-1111-111111111111"));
            var t = new EntityReference("edu_term", new Guid("22222222-2222-2222-2222-222222222222"));
            Assert.Equal("11111111-1111-1111-1111-111111111111|22222222-2222-2222-2222-222222222222", FeeRules.InvoiceKey(s, t));
        }
    }
}

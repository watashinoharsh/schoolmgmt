using System;
using System.Collections.Generic;
using Microsoft.Xrm.Sdk;
using Xunit;

namespace EduCore.Plugins.Tests
{
    public class ReportCardRulesTests
    {
        private static WeightedMark M(decimal p, decimal w) { return new WeightedMark(p, w); }

        [Fact]
        public void Subject_percent_is_weighted_by_assessment_weightage()
        {
            // (80 x 20 + 60 x 30 + 100 x 50) / 100 = 84
            Assert.Equal(84m, ReportCardRules.SubjectPercent(new[] { M(80m, 20m), M(60m, 30m), M(100m, 50m) }));
        }

        [Fact]
        public void Only_graded_assessments_count_so_the_weights_are_renormalised()
        {
            // Only the 20 and 30 weighted assessments are graded: (80 x 20 + 60 x 30) / 50 = 68
            Assert.Equal(68m, ReportCardRules.SubjectPercent(new[] { M(80m, 20m), M(60m, 30m) }));
        }

        [Fact]
        public void No_graded_assessments_gives_no_percent()
        {
            Assert.Null(ReportCardRules.SubjectPercent(new WeightedMark[0]));
            Assert.Null(ReportCardRules.SubjectPercent(null));
            Assert.Null(ReportCardRules.SubjectPercent(new[] { M(90m, 0m) }));
        }

        [Fact]
        public void Subject_percent_rounds_to_two_places_away_from_zero()
        {
            // (50 x 1 + 51 x 1 + 51 x 1) / 3 = 50.6667
            Assert.Equal(50.67m, ReportCardRules.SubjectPercent(new[] { M(50m, 1m), M(51m, 1m), M(51m, 1m) }));
            Assert.Equal(0.01m, ReportCardRules.SubjectPercent(new[] { M(0.005m, 1m) }));
        }

        [Fact]
        public void Overall_is_the_plain_average_of_subjects_that_have_a_percent()
        {
            Assert.Equal(75m, ReportCardRules.Overall(new decimal?[] { 90m, 60m, null }));
            Assert.Equal(33.33m, ReportCardRules.Overall(new decimal?[] { 0m, 0m, 100m }));
            Assert.Null(ReportCardRules.Overall(new decimal?[] { null, null }));
            Assert.Null(ReportCardRules.Overall(null));
        }

        [Fact]
        public void Overall_letter_uses_the_grade_bands()
        {
            var bands = new[] { new GradeBandInfo(0m, "F"), new GradeBandInfo(50m, "C"), new GradeBandInfo(75m, "B"), new GradeBandInfo(90m, "A") };
            Assert.Equal("B", AcademicsRules.GradeLetter(ReportCardRules.Overall(new decimal?[] { 90m, 60m }), bands));
        }

        [Fact]
        public void Published_cards_cannot_be_changed_or_deleted()
        {
            Assert.NotNull(ReportCardRules.ValidateCardChange(ReportCardRules.Published, ReportCardRules.Published, false));
            Assert.NotNull(ReportCardRules.ValidateCardChange(ReportCardRules.Published, ReportCardRules.Draft, false));
            Assert.NotNull(ReportCardRules.ValidateCardChange(ReportCardRules.Published, null, true));
        }

        [Fact]
        public void Draft_cards_can_be_changed_deleted_and_published()
        {
            Assert.Null(ReportCardRules.ValidateCardChange(ReportCardRules.Draft, ReportCardRules.Draft, false));
            Assert.Null(ReportCardRules.ValidateCardChange(ReportCardRules.Draft, ReportCardRules.Published, false));
            Assert.Null(ReportCardRules.ValidateCardChange(ReportCardRules.Draft, null, true));
            Assert.Null(ReportCardRules.ValidateCardChange(null, ReportCardRules.Draft, false));
        }

        [Fact]
        public void Lines_are_fixed_once_the_card_is_published()
        {
            Assert.NotNull(ReportCardRules.ValidateLineChange(ReportCardRules.Published));
            Assert.Null(ReportCardRules.ValidateLineChange(ReportCardRules.Draft));
            Assert.Null(ReportCardRules.ValidateLineChange(null));
        }

        [Fact]
        public void Keys_use_the_shared_format()
        {
            var a = new EntityReference("edu_student", new Guid("11111111-1111-1111-1111-111111111111"));
            var b = new EntityReference("edu_term", new Guid("22222222-2222-2222-2222-222222222222"));
            Assert.Equal("11111111-1111-1111-1111-111111111111|22222222-2222-2222-2222-222222222222", ReportCardRules.Key(a, b));
        }
    }
}

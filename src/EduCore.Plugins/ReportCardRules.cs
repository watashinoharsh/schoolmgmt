using System;
using System.Collections.Generic;
using Microsoft.Xrm.Sdk;

namespace EduCore.Plugins
{
    /// <summary>A graded assessment result for one subject: the student's percentage and the assessment weightage.</summary>
    public sealed class WeightedMark
    {
        public decimal Percentage { get; private set; }
        public decimal Weightage { get; private set; }
        public WeightedMark(decimal percentage, decimal weightage) { Percentage = percentage; Weightage = weightage; }
    }

    /// <summary>Pure report card rules (LLD section 4): weighted subject percentage, overall average, immutability once Published.</summary>
    public static class ReportCardRules
    {
        public const string ReportCard = "edu_reportcard";
        public const string Line = "edu_reportcardline";

        // edu_reportstatus
        public const int Draft = 859680000;
        public const int Published = 859680001;

        /// <summary>Sum(percentage x weightage) / sum(weightage) over graded assessments, to two places; null when none count.</summary>
        public static decimal? SubjectPercent(IEnumerable<WeightedMark> marks)
        {
            decimal weighted = 0m, weights = 0m;
            if (marks != null)
                foreach (var m in marks)
                {
                    if (m.Weightage <= 0m) continue;
                    weighted += m.Percentage * m.Weightage;
                    weights += m.Weightage;
                }
            if (weights <= 0m) return null;
            return Math.Round(weighted / weights, 2, MidpointRounding.AwayFromZero);
        }

        /// <summary>Average of the subject percentages that exist (an ungraded subject is left out); null when there are none.</summary>
        public static decimal? Overall(IEnumerable<decimal?> subjectPercents)
        {
            decimal sum = 0m; int n = 0;
            if (subjectPercents != null)
                foreach (var p in subjectPercents)
                    if (p.HasValue) { sum += p.Value; n++; }
            if (n == 0) return null;
            return Math.Round(sum / n, 2, MidpointRounding.AwayFromZero);
        }

        /// <summary>A Published report card cannot be edited or deleted, and cannot go back to Draft.</summary>
        public static string ValidateCardChange(int? oldStatus, int? newStatus, bool isDelete)
        {
            if (oldStatus != Published) return null;
            if (isDelete) return "A published report card cannot be deleted.";
            return "A published report card cannot be changed.";
        }

        /// <summary>Lines belong to a card; they are fixed once the card is Published.</summary>
        public static string ValidateLineChange(int? cardStatus)
        {
            return cardStatus == Published ? "The lines of a published report card cannot be changed." : null;
        }

        public static string Key(EntityReference student, EntityReference term) { return EduKey.Build(student, term); }
        public static string LineKey(EntityReference card, EntityReference assignment) { return EduKey.Build(card, assignment); }
    }
}

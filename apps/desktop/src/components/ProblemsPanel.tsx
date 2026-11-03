import type { ValidationIssue, ValidationReport } from "../lib/types";

interface ProblemsPanelProps {
  report: ValidationReport;
  onClose: () => void;
}

function issueClass(issue: ValidationIssue): string {
  return "problem problem--" + issue.severity;
}

export function ProblemsPanel({ report, onClose }: ProblemsPanelProps) {
  return (
    <section className="problems">
      <header className="problems__head">
        <strong className="problems__title">
          校验结果
          <span className="problems__stat problems__stat--error">{report.errors} 错误</span>
          <span className="problems__stat problems__stat--warn">{report.warnings} 警告</span>
        </strong>
        <button type="button" className="btn btn--tiny" onClick={onClose}>
          关闭
        </button>
      </header>
      <div className="problems__body">
        {report.issues.length === 0 ? (
          <p className="problems__empty">工作流通过校验，可以运行。</p>
        ) : (
          report.issues.map((issue, index) => (
            <div className={issueClass(issue)} key={issue.code + ":" + issue.path + ":" + index}>
              <span className="problem__severity">{issue.severity}</span>
              <span className="problem__code">{issue.code}</span>
              <span className="problem__path">{issue.path}</span>
              <span className="problem__message">{issue.message}</span>
            </div>
          ))
        )}
      </div>
    </section>
  );
}

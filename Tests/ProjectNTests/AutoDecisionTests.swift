import Foundation
import Testing
@testable import ProjectN

struct AutoDecisionTests {
    @Test func featuredModelsAreTheNewestOfEachFamily() {
        func models(_ ids: [String]) -> [ModelCatalog.Model] { ids.map { .init(id: $0, label: $0, efforts: []) } }
        let claude = models(["claude-fable-5-2", "claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1",
                             "claude-opus-5", "claude-opus-4-5-20251101", "claude-haiku-4-5-20251001"])
        #expect(ModelCatalog.featured(claude).map(\.id) ==
                       ["claude-fable-5-2", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
        let codex = models(["gpt-6.2-sol", "gpt-6.2-astra", "gpt-6.1-terra", "gpt-6.1-sol", "gpt-6-luna", "gpt-5.6-terra"])
        #expect(ModelCatalog.featured(codex).map(\.id) == ["gpt-6.2-sol", "gpt-6.2-astra", "gpt-6.1-terra", "gpt-6-luna"])
    }

    @Test func onlyLabelledLinesCountAsAssumptions() {
        let answer = """
        Listo.
        - **Supuesto:** usé la hoja más reciente.
        Asumí que el dominio es el de producción.
        - Decisiones SEO basadas en datos.
        - README con arquitectura, fases y decisiones: actualizado.
        Assumption: staging only.
        """
        #expect(AutoDecision.assumptions(in: answer) ==
                       ["Supuesto: usé la hoja más reciente.", "Asumí que el dominio es el de producción.", "Assumption: staging only."])
    }

    @Test func collectsClaudeAndCodexAutoModeEntries() {
        var codex = AgentTask(agentID: UUID(), agentName: "Dev", projectID: UUID(), projectName: "Demo", instruction: "x",
                              origin: TaskOrigin(kind: .local), runtime: .codexCLI, model: "gpt-6.2-sol", permission: .readOnly)
        codex.result = "Supuesto: ignorado porque ya registró decisiones."
        let id = codex.id.uuidString
        func line(_ fields: [String: String]) -> String {
            var f = fields
            f["at"] = "2026-11-26T10:00:00Z"
            return String(data: try! JSONSerialization.data(withJSONObject: f, options: [.sortedKeys]), encoding: .utf8)!
        }
        let audit = [
            line(["event": "decision.auto", "task": id, "decision": "Usé SMTP", "why": "ya estaba configurado"]),
            line(["event": "question.skipped", "task": id, "question": "¿Publico?"]),
            line(["event": "prompt.auto_approved", "task": id, "why": "Auto mode", "call": "Drive · upload_file"]),
            line(["event": "prompt.auto_approved", "task": id, "why": "Auto mode", "call": "projectn · list_agents"]),
            line(["event": "prompt.auto_approved", "task": id, "why": "autonomy Balanced", "call": "ls"]),
            line(["event": "tool.auto_approved", "task": UUID().uuidString, "call": "another request"]),
        ].joined(separator: "\n")
        let found = AutoDecision.collect(audit: audit, tasks: [codex], autoModeAgents: [codex.agentID])
        #expect(found.map(\.text) == ["Usé SMTP", "¿Publico?", "Drive · upload_file"])
        #expect(found.map(\.kind) == [.decision, .question, .action])
        #expect(found.allSatisfy { $0.runtime == .codexCLI })
    }
}

import Observation
#if !AMBER_MAC_PREVIEW
@preconcurrency import Shared
#endif

/// Transient, main-actor state owned by one conversation run.
@MainActor @Observable
final class PersonaStatusOwner {
    private(set) var phrase: String?
    #if !AMBER_MAC_PREVIEW
    @ObservationIgnored private let controller = PersonaStatusController()
    #endif

    func refresh(assistant: String, persona: String, recent: [String], latest: String,
                 isAddition: Bool, generate: @escaping @MainActor (String) async -> String?) {
        #if !AMBER_MAC_PREVIEW
        controller.refresh(
            assistant: assistant, persona: persona, recent: recent, latest: latest,
            isAddition: isAddition, request: ProviderRequest(generate: generate) { [weak self] value in
                if self?.phrase != value { self?.phrase = value }
            }
        )
        #endif
    }

    func clear() {
        #if !AMBER_MAC_PREVIEW
        controller.clear()
        #endif
        if phrase != nil { phrase = nil }
    }
}

#if !AMBER_MAC_PREVIEW
@MainActor private final class ProviderRequest: @preconcurrency PersonaStatusRequest {
    private let generate: @MainActor (String) async -> String?
    private let update: @MainActor (String?) -> Void
    private var task: Task<Void, Never>?

    init(generate: @escaping @MainActor (String) async -> String?, update: @escaping @MainActor (String?) -> Void) {
        self.generate = generate
        self.update = update
    }

    func start(prompt: String, reply: PersonaStatusReply) {
        task = Task {
            let raw = await generate(prompt)
            if !Task.isCancelled { reply.submit(raw: raw) }
        }
    }

    func cancel() { task?.cancel(); task = nil }
    func publish(phrase: String?) { update(phrase) }
}
#endif

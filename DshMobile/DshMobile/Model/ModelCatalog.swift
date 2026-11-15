import Foundation

/// One selectable model, flattened out of the provider group that carries it.
///
/// The bridge joins the provider identity onto every row so a picker cell needs
/// no parent lookup.
struct ModelOption: Decodable, Identifiable, Equatable {
    /// Stable identity: `provider/model`.
    let key: String
    let id: String
    /// The model's display name, which is not its id.
    let name: String
    let description: String?
    let badge: ModelBadge?
    /// Effort choices, or nil when the route exposes none.
    let reasoning: ModelReasoning?

    /// Whether this model offers a reasoning-effort control at all.
    var hasReasoning: Bool {
        guard let reasoning else { return false }
        return !reasoning.efforts.isEmpty
    }

    struct ModelBadge: Decodable, Equatable {
        let text: BadgeText
        let tone: String?
    }

    /// Badge copy arrives either as a plain string or a locale map.
    enum BadgeText: Decodable, Equatable {
        case plain(String)
        case localized(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .plain(value)
                return
            }
            let map = try container.decode([String: String].self)
            self = .localized(map["zh"] ?? map["en"] ?? map.values.first ?? "")
        }

        var text: String {
            switch self {
            case let .plain(value), let .localized(value): return value
            }
        }
    }

    struct ModelReasoning: Decodable, Equatable {
        let efforts: [Effort]
        let defaultEffort: String?

        struct Effort: Decodable, Equatable, Identifiable {
            let id: String
            let name: String
            let description: String?
        }
    }
}

/// One provider and its models, as the catalog groups them.
struct ModelGroup: Decodable, Identifiable, Equatable {
    let provider: String
    let providerName: String
    let models: [ModelOption]

    var id: String { provider }
}

/// The full picker payload.
struct ModelCatalog: Decodable, Equatable {
    let default: Selection
    let groups: [ModelGroup]
    let failures: [Failure]

    struct Selection: Decodable, Equatable {
        let provider: String
        let model: String
        let reasoningEffort: String?
    }

    struct Failure: Decodable, Equatable {
        let id: String
        let message: String
    }

    /// Find one model by its `provider/model` key.
    /// @param provider - provider id.
    /// @param model - model id.
    /// @returns the option, or nil when the catalog no longer offers it.
    func option(provider: String, model: String) -> (ModelOption, ModelGroup)? {
        for group in groups where group.provider == provider {
            if let match = group.models.first(where: { $0.id == model }) {
                return (match, group)
            }
        }
        return nil
    }
}

/// The selection installed on one Session.
struct SessionModel: Decodable, Equatable {
    let provider: String
    let model: String
    let reasoningEffort: String?

    /// Human label, preferring the catalog name when it is known.
    /// @param catalog - the catalog to look the model up in.
    /// @returns the display name, falling back to the raw model id.
    func displayName(in catalog: ModelCatalog?) -> String {
        catalog?.option(provider: provider, model: model)?.0.name ?? model
    }

    /// The provider's display name.
    /// @param catalog - the catalog to look the provider up in.
    /// @returns the provider name, falling back to the provider id.
    func providerName(in catalog: ModelCatalog?) -> String {
        catalog?.option(provider: provider, model: model)?.1.providerName ?? provider
    }
}

/// Result of switching a Session's model.
struct ModelSwitchResult: Decodable {
    let selected: SessionModel
    let current: SessionModel?
}

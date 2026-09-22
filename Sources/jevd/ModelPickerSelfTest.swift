import Foundation
import JevCore

/// The model picker: what the gateway offers, and which one is in force.
///
/// The fixture below is a real `/v1/models` response captured from the running
/// gateway, pasted in rather than loaded from a file. `Sources/jevd` is an
/// executableTarget with `resources: []`, and `SnapshotSource.swift` sets out
/// why `Bundle.module` is unusable here — a loose .json would warn at build
/// time and be missing from the signed app, so the test would pass locally and
/// vanish in the thing people actually run.
enum ModelPickerSelfTest {

    /// Trimmed to the fields we parse. Twelve models, three shapes: plain,
    /// `@sub`, and the virtual `oag/*` rungs.
    static let liveResponse = #"""
{
  "object": "list",
  "data": [
    {
      "id": "oag/cheap",
      "object": "model",
      "display_name": "OAG: cheap",
      "owned_by": "oag",
      "oag": {
        "tier": "cheap",
        "provider": "oag",
        "virtual": true,
        "channel": null
      }
    },
    {
      "id": "oag/frontier",
      "object": "model",
      "display_name": "OAG: frontier",
      "owned_by": "oag",
      "oag": {
        "tier": "frontier",
        "provider": "oag",
        "virtual": true,
        "channel": null
      }
    },
    {
      "id": "xai/grok-4.6",
      "object": "model",
      "display_name": "xAI: grok-4.6",
      "owned_by": "xai",
      "oag": {
        "tier": "cheap",
        "provider": "xai",
        "virtual": false,
        "channel": null
      }
    },
    {
      "id": "xai/grok-4.6@sub",
      "object": "model",
      "display_name": "xAI: grok-4.6 · subscription",
      "owned_by": "xai",
      "oag": {
        "tier": "cheap",
        "provider": "xai",
        "virtual": false,
        "channel": "sub"
      }
    },
    {
      "id": "xai/grok-4.7",
      "object": "model",
      "display_name": "xAI: grok-4.7",
      "owned_by": "xai",
      "oag": {
        "tier": "cheap",
        "provider": "xai",
        "virtual": false,
        "channel": null
      }
    },
    {
      "id": "xai/grok-4.7@sub",
      "object": "model",
      "display_name": "xAI: grok-4.7 · subscription",
      "owned_by": "xai",
      "oag": {
        "tier": "cheap",
        "provider": "xai",
        "virtual": false,
        "channel": "sub"
      }
    },
    {
      "id": "openai/gpt-5.6-terra",
      "object": "model",
      "display_name": "OpenAI: gpt-5.6-terra",
      "owned_by": "openai",
      "oag": {
        "tier": "frontier",
        "provider": "openai",
        "virtual": false,
        "channel": null
      }
    },
    {
      "id": "openai/gpt-5.6-terra@sub",
      "object": "model",
      "display_name": "OpenAI: gpt-5.6-terra · subscription",
      "owned_by": "openai",
      "oag": {
        "tier": "frontier",
        "provider": "openai",
        "virtual": false,
        "channel": "sub"
      }
    },
    {
      "id": "openai/gpt-5.5",
      "object": "model",
      "display_name": "OpenAI: gpt-5.5",
      "owned_by": "openai",
      "oag": {
        "tier": null,
        "provider": "openai",
        "virtual": false,
        "channel": null
      }
    },
    {
      "id": "openai/gpt-5.5@sub",
      "object": "model",
      "display_name": "OpenAI: gpt-5.5 · subscription",
      "owned_by": "openai",
      "oag": {
        "tier": null,
        "provider": "openai",
        "virtual": false,
        "channel": "sub"
      }
    },
    {
      "id": "openai/gpt-5.6-luna",
      "object": "model",
      "display_name": "OpenAI: gpt-5.6-luna",
      "owned_by": "openai",
      "oag": {
        "tier": null,
        "provider": "openai",
        "virtual": false,
        "channel": null
      }
    },
    {
      "id": "openai/gpt-5.6-luna@sub",
      "object": "model",
      "display_name": "OpenAI: gpt-5.6-luna · subscription",
      "owned_by": "openai",
      "oag": {
        "tier": null,
        "provider": "openai",
        "virtual": false,
        "channel": "sub"
      }
    }
  ],
  "oag": {
    "mode": "passthrough",
    "claude_code_aliases": false,
    "budget": {
      "pressure": "normal"
    },
    "providers": [
      {
        "provider": "openai",
        "serving": true,
        "reason": "serving",
        "until": null,
        "remaining_pct": 71.0,
        "reserve_pct": 10.0,
        "kinds": [
          "sub"
        ],
        "models": 3
      },
      {
        "provider": "xai",
        "serving": true,
        "reason": "serving",
        "until": null,
        "remaining_pct": 95.0,
        "reserve_pct": 10.0,
        "kinds": [
          "sub"
        ],
        "models": 2
      }
    ]
  }
}
"""#

    static func run() -> [String] {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures.append("models: \(what)") }
        }

        // ---- Which model is in force ----
        //
        // Asserted on the pure function, never on `WebTextModel.model`: the
        // hook is installed just before the self-tests run, so that would
        // depend on whatever this Mac happens to have stored.
        check(WebModelChoice.effective(stored: "xai/grok-4.7", environment: "openai/gpt-5.5")
                == "xai/grok-4.7",
              "a picked model beats the environment — or the menu is a lie")
        check(WebModelChoice.effective(stored: nil, environment: "openai/gpt-5.5")
                == "openai/gpt-5.5",
              "with nothing picked, the environment is used")
        check(WebModelChoice.effective(stored: nil, environment: nil) == WebModelChoice.fallback,
              "and with neither, the built-in default")
        check(WebModelChoice.effective(stored: "", environment: nil) == WebModelChoice.fallback,
              "an empty stored value is not a choice")
        check(WebModelChoice.effective(stored: "   ", environment: nil) == WebModelChoice.fallback,
              "nor is a blank one")
        check(WebModelChoice.effective(stored: nil, environment: "  ") == WebModelChoice.fallback,
              "nor is a blank environment variable")
        check(WebModelChoice.fallback == "openai/gpt-5.6-luna",
              "the default is unchanged — picking grok is the feature, not a new hardcoded value")
        check(WebModelChoice.source(stored: "x", environment: nil) == "the menu bar",
              "the log can say the choice came from the menu")
        check(WebModelChoice.source(stored: nil, environment: "x") == "ALLOWLY_WEB_TEXT_MODEL",
              "or from the environment")
        check(WebModelChoice.source(stored: nil, environment: nil) == "the built-in default",
              "or from neither")

        // ---- Reading the gateway's answer ----
        guard let catalog = ModelCatalog.parse(Data(liveResponse.utf8)) else {
            return failures + ["models: the captured response does not parse at all"]
        }
        check(catalog.models.count == 12, "all twelve models are read")
        let ids = Set(catalog.models.map(\.id))
        check(ids.contains("xai/grok-4.7"), "grok-4.7 is there — the one this was built for")
        check(ids.contains("openai/gpt-5.6-luna"), "and the current default")
        check(ids.contains("oag/cheap"), "and the virtual rungs")

        let grok = catalog.models.first { $0.id == "xai/grok-4.7" }
        check(grok?.displayName == "xAI: grok-4.7",
              "the gateway's own label is used, not the bare id")
        check(grok?.provider == "xai", "the provider is read")
        check(grok?.isVirtual == false, "a real model is not marked virtual")
        check(grok?.usesSubscription == false, "and the plain one is not a seat")
        check(catalog.models.first { $0.id == "xai/grok-4.7@sub" }?.usesSubscription == true,
              "the @sub variant is a seat")
        check(catalog.models.first { $0.id == "oag/cheap" }?.isVirtual == true,
              "an oag rung is virtual")

        // ---- How they are grouped ----
        let groups = ModelCatalog.groups(catalog.models)
        check(groups.count == 3, "three sections")
        check(groups.first?.title == "Models", "plain models come first")
        check(groups.first?.models.allSatisfy { !$0.usesSubscription && !$0.isVirtual } == true,
              "and contain nothing that spends a seat or picks for you")
        check(groups.contains { $0.title == "Subscription seat" }, "seats have their own section")
        check(groups.contains { $0.title == "Choose for me" }, "so do the auto rungs")
        check(groups.reduce(0) { $0 + $1.models.count } == 12, "and nothing is lost between them")
        check(ModelCatalog.groups([]).isEmpty, "no models means no empty sections")

        // ---- What it says when something is wrong ----
        check(ModelCatalog.summary(catalog) == nil,
              "a healthy gateway needs no warning line")
        let stalled = ModelCatalog.Catalog(
            models: [],
            providers: [ModelCatalog.Provider(name: "xai", serving: false, reason: "exhausted")],
            pressure: "critical")
        let text = ModelCatalog.summary(stalled) ?? ""
        check(text.contains("xai") && text.contains("exhausted"),
              "an empty list says which provider ran out and why")
        check(!text.contains("95") && !text.contains("%"),
              "and never how much allowance is left — that is nobody's business")
        let noProviders = ModelCatalog.Catalog(models: [], providers: [], pressure: nil)
        check(ModelCatalog.summary(noProviders) != nil,
              "an empty list with no explanation still says something")

        // ---- Shapes that must not crash ----
        check(ModelCatalog.parse(Data("not json".utf8)) == nil, "rubbish parses to nothing")
        check(ModelCatalog.parse(Data("{}".utf8)) == nil, "so does a response with no data")
        let bare = ModelCatalog.parse(Data(#"{"data":[{"id":"a/b"}]}"#.utf8))
        check(bare?.models.count == 1, "an entry with no oag block is still a model")
        check(bare?.models.first?.displayName == "a/b", "and falls back to its id for a name")
        check(bare?.providers.isEmpty == true, "a missing envelope is not a failure")
        check(ModelCatalog.parse(Data(#"{"data":[{"id":""}]}"#.utf8))?.models.isEmpty == true,
              "an entry with no id is dropped rather than shown blank")

        // ---- Staleness ----
        var fresh = ModelCatalog.Snapshot()
        check(ModelCatalog.isStale(fresh), "never fetched is stale")
        fresh.attemptedAt = Date()
        check(!ModelCatalog.isStale(fresh), "just attempted is not")
        fresh.attemptedAt = Date(timeIntervalSinceNow: -ModelCatalog.freshness - 1)
        check(ModelCatalog.isStale(fresh), "an old attempt is stale again")
        // A FAILED attempt counts, or a refused key refires on every open.
        var failed = ModelCatalog.Snapshot()
        failed.failure = .refused
        failed.attemptedAt = Date()
        check(!ModelCatalog.isStale(failed), "a recent failure is remembered, not retried at once")

        return failures
    }
}

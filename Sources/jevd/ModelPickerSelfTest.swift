import Foundation
import JevCore
import JevWeb

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
        check(WebModelChoice.effective(stored: nil, environment: nil) == nil,
              "and with neither, NOTHING — there is no default to fall back to")
        check(WebModelChoice.effective(stored: "", environment: nil) == nil,
              "an empty stored value is not a choice")
        check(WebModelChoice.effective(stored: "   ", environment: nil) == nil,
              "nor is a blank one")
        check(WebModelChoice.effective(stored: nil, environment: "  ") == nil,
              "nor is a blank environment variable")
        check(WebModelChoice.source(stored: nil, environment: nil) == "nothing",
              "and the log says so rather than naming a model nobody picked")
        check(WebModelChoice.effective(stored: "xai/grok-4.7", environment: "openai/gpt-5.5")
                == WebTextModel.effective(stored: "xai/grok-4.7", environment: "openai/gpt-5.5"),
              "the menu resolves the model exactly as the request does")
        check(WebModelChoice.source(stored: "x", environment: nil) == "the menu bar",
              "the log can say the choice came from the menu")
        check(WebModelChoice.source(stored: nil, environment: "x") == "the environment",
              "or from the environment — either spelling of the variable, so it is not named")

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
            providers: [ModelCatalog.Provider(name: "xai", serving: false, reason: "exhausted")])
        let text = ModelCatalog.summary(stalled) ?? ""
        check(text.contains("xai") && text.contains("exhausted"),
              "an empty list says which provider ran out and why")
        check(!text.contains("95") && !text.contains("%"),
              "and never how much allowance is left — that is nobody's business")
        let noProviders = ModelCatalog.Catalog(models: [], providers: [])
        check(ModelCatalog.summary(noProviders) != nil,
              "an empty list with no explanation still says something")

        // ---- When there is no gateway at all ----
        //
        // The case nobody tests because it never happens on the machine the
        // thing was written on: Allowly installed, gateway never heard of.
        check(ModelCatalog.Failure.unreachable("Connection refused").help != nil,
              "a gateway that is not answering offers somewhere to go")
        check(ModelCatalog.Failure.noKey.help != nil,
              "and so does having no key")
        check(ModelCatalog.Failure.refused.help == nil,
              "a refused key does not — the gateway is right there, the key is wrong")
        check(ModelCatalog.Failure.unreadable.help == nil,
              "nor does a garbled answer — that is a bug to report, not a setup step")
        check(ModelCatalog.Failure.unreachable("x").help?.url == ModelCatalog.repository,
              "the link is the constant in this binary")
        check(ModelCatalog.repository.scheme == "https",
              "over https, because it is a link handed to someone's browser")
        // The transport's own words go in the failure and must not come back
        // out as somewhere to send a person.
        check(ModelCatalog.Failure.unreachable("http://evil.example").help?.url
                == ModelCatalog.repository,
              "and never anything carried in the failure itself")

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

        // ---- At most one row is ticked ----
        //
        // Two once were. A "Use the default" row ticked whenever nothing was
        // stored, and every catalog row ticked when its id matched the model
        // in force — and with nothing stored that WAS the default, which was
        // in the list. A matrix, not one example, because the bug was one
        // unconsidered combination rather than a wrong line.
        let served = ["openai/gpt-5.6-luna", "xai/grok-4.7", "oag/cheap"]
        check(WebModelChoice.tick(chosen: nil, listed: served) == nil,
              "nothing picked ticks nothing — no row may claim to be in force")
        check(WebModelChoice.tick(chosen: "", listed: served) == nil,
              "an empty stored value ticks nothing either")
        check(WebModelChoice.tick(chosen: "  ", listed: served) == nil,
              "nor does a blank one")
        check(WebModelChoice.tick(chosen: "xai/grok-4.7", listed: served) == .model("xai/grok-4.7"),
              "a picked model that is served ticks its own row")
        check(WebModelChoice.tick(chosen: "openai/gpt-5.6-luna", listed: served)
                == .model("openai/gpt-5.6-luna"),
              "including the model that used to be the default — it is now just a model")
        check(WebModelChoice.tick(chosen: "xai/grok-9", listed: served)
                == .noLongerOffered("xai/grok-9"),
              "a picked model the gateway dropped ticks the row that says so")
        check(WebModelChoice.tick(chosen: "xai/grok-4.7", listed: []) == .noLongerOffered("xai/grok-4.7"),
              "and so does a pick with no list at all")

        // No loop here counting checkmarks. A first draft had one, and it was
        // vacuous: `Tick` is an enum, so "exactly one row is ticked" is true
        // by construction and no arrangement of inputs can make the count
        // anything but one. That IS the fix — the menu asks once and compares,
        // instead of deciding each row on its own and contradicting itself —
        // but it is carried by the type, not by an assertion, and an assertion
        // that cannot fail is worse than none because it reads like cover.
        // What is worth pinning is the answer for each case, which is above.

        return failures
    }
}

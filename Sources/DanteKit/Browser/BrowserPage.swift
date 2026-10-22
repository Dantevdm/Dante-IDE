import Foundation
import Yams

/// Where the agents' own browser may go: the app on this Mac (localhost, 127.0.0.1, ::1, and
/// names ending .localhost or .test) and hosts the project lists in `.dante/project.yaml`:
///
///     browser:
///       hosts: [staging.example.com]   # and their subdomains
///
/// Pages may load scripts, styles and images from anywhere, as any page does, but the page
/// itself never moves to another site: a link or form that leaves is stopped.
public struct BrowserHosts: Equatable, Sendable {
    public var extra: [String]

    public init(extra: [String] = []) {
        self.extra = extra.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.filter { !$0.isEmpty }
    }

    public static let local: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"]

    public func allows(_ url: URL) -> Bool {
        if url.scheme == "about" || url.scheme == "data" || url.scheme == "blob" { return true }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
        if Self.local.contains(host) || host.hasSuffix(".localhost") || host.hasSuffix(".test") { return true }
        return extra.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Why a page is refused, for the agent.
    public func refusal(_ url: URL) -> String {
        let listed = extra.isEmpty ? "" : " and \(extra.joined(separator: ", "))"
        return "The browser only visits the app on this Mac (localhost, 127.0.0.1, *.localhost, *.test)\(listed). \(url.absoluteString) isn’t one; the person can add a test host under browser: hosts: in .dante/project.yaml."
    }

    public static func load(projectRoot: URL) -> BrowserHosts {
        let url = projectRoot.appending(path: ".dante/project.yaml")
        guard let yaml = try? String(contentsOf: url, encoding: .utf8) else { return BrowserHosts() }
        return parse(yaml)
    }

    public static func parse(_ yaml: String) -> BrowserHosts {
        guard let root = (try? Yams.load(yaml: yaml)) as? [String: Any], let browser = root["browser"] as? [String: Any] else { return BrowserHosts() }
        let hosts = (browser["hosts"] as? [Any] ?? []).compactMap { $0 as? String }
        // A listed URL counts by its host.
        return BrowserHosts(extra: hosts.map { URL(string: $0)?.host(percentEncoded: false) ?? $0 })
    }

    /// A URL the agent typed: `localhost:3000/orders` gets http://.
    public static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") || trimmed.hasPrefix("about:") { return URL(string: trimmed) }
        if trimmed.hasPrefix(":") { return URL(string: "http://localhost" + trimmed) }
        if trimmed.allSatisfy(\.isNumber) { return URL(string: "http://localhost:" + trimmed) }
        return URL(string: "http://" + trimmed)
    }
}

/// What the browser saw on a page, read by `BrowserScripts.report` and told to the agent as
/// text: the page's words, numbered controls to click and type into, and what went wrong.
public struct BrowserReport: Codable, Equatable, Sendable {
    public struct Control: Codable, Equatable, Sendable {
        public var ref: Int
        /// link, button, textbox, checkbox, select…
        public var role: String
        public var label: String
        public var value: String?
        public var href: String?
        public var disabled: Bool?

        public init(ref: Int, role: String, label: String, value: String? = nil, href: String? = nil, disabled: Bool? = nil) {
            self.ref = ref
            self.role = role
            self.label = label
            self.value = value
            self.href = href
            self.disabled = disabled
        }
    }

    public var url: String
    public var title: String
    public var text: String
    public var controls: [Control]
    /// console.error, uncaught errors and rejections, and resources that didn't load.
    public var errors: [String]
    /// fetch and XHR calls that failed or answered 400 or more.
    public var requests: [String]
    public var width: Int
    public var height: Int

    public init(url: String, title: String, text: String, controls: [Control], errors: [String] = [], requests: [String] = [],
                width: Int = 0, height: Int = 0) {
        self.url = url
        self.title = title
        self.text = text
        self.controls = controls
        self.errors = errors
        self.requests = requests
        self.width = width
        self.height = height
    }

    public static let textLimit = 6000
    public static let controlLimit = 150

    /// The report as the agent reads it. `status` is the page's HTTP status when known.
    public func rendered(status: Int? = nil) -> String {
        var lines = ["\(title.isEmpty ? "(no title)" : title) — \(url)" + (status.map { $0 >= 400 ? " (HTTP \($0))" : "" } ?? "")]
        if width > 0 { lines.append("Viewport \(width)×\(height).") }
        let words = text.count > Self.textLimit ? String(text.prefix(Self.textLimit)) + " …(more on the page)" : text
        lines += ["", "Text:", words.isEmpty ? "(nothing visible)" : words]
        if !controls.isEmpty {
            lines += ["", "Controls (use the number as ref):"]
            for control in controls.prefix(Self.controlLimit) {
                var line = "[\(control.ref)] \(control.role) “\(control.label)”"
                if let value = control.value, !value.isEmpty { line += " = “\(value)”" }
                if let href = control.href, !href.isEmpty { line += " → \(href)" }
                if control.disabled == true { line += " (disabled)" }
                lines.append(line)
            }
            if controls.count > Self.controlLimit { lines.append("…and \(controls.count - Self.controlLimit) more.") }
        }
        if !errors.isEmpty { lines += ["", "Page errors:"] + errors.suffix(20).map { "- " + $0 } }
        if !requests.isEmpty { lines += ["", "Failed requests:"] + requests.suffix(20).map { "- " + $0 } }
        if errors.isEmpty && requests.isEmpty { lines += ["", "No page errors or failed requests."] }
        return lines.joined(separator: "\n")
    }
}

/// The JavaScript the browser runs in pages. Errors and failed requests are caught from the
/// start of every page; the report numbers visible controls with `data-dante-ref`.
public enum BrowserScripts {
    /// Injected at document start in every frame.
    public static let watch = #"""
    (() => {
      if (window.__dante) return;
      const d = window.__dante = { errors: [], requests: [] };
      const keep = (list, line) => { list.push(String(line).slice(0, 300)); if (list.length > 50) list.shift(); };
      const original = console.error;
      console.error = function (...args) {
        keep(d.errors, "console.error: " + args.map(a => a instanceof Error ? a.message : (typeof a === "object" ? JSON.stringify(a) : String(a))).join(" "));
        return original.apply(this, args);
      };
      addEventListener("error", e => {
        const t = e.target;
        if (t && t !== window && (t.src || t.href)) keep(d.errors, "Didn’t load: " + (t.src || t.href));
        else keep(d.errors, (e.message || "Error") + (e.filename ? " (" + e.filename.split("/").pop() + ":" + e.lineno + ")" : ""));
      }, true);
      addEventListener("unhandledrejection", e => keep(d.errors, "Unhandled rejection: " + (e.reason && e.reason.message || e.reason)));
      const fetch0 = window.fetch;
      if (fetch0) window.fetch = function (input, init) {
        const method = (init && init.method || (input && input.method) || "GET").toUpperCase();
        const url = typeof input === "string" ? input : (input && input.url) || String(input);
        return fetch0.apply(this, arguments).then(r => { if (r.status >= 400) keep(d.requests, method + " " + url + " → " + r.status); return r; },
          err => { keep(d.requests, method + " " + url + " → failed: " + (err && err.message || err)); throw err; });
      };
      const open0 = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.addEventListener("loadend", () => {
          if (this.status === 0 || this.status >= 400) keep(d.requests, String(method).toUpperCase() + " " + url + " → " + (this.status || "failed"));
        });
        return open0.apply(this, arguments);
      };
    })();
    """#

    /// Returns the page as `BrowserReport` JSON.
    public static let report = #"""
    (() => {
      const d = window.__dante || { errors: [], requests: [] };
      const visible = el => {
        const r = el.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) return false;
        const s = getComputedStyle(el);
        return s.visibility !== "hidden" && s.display !== "none" && s.opacity !== "0";
      };
      const clean = t => (t || "").replace(/\s+/g, " ").trim().slice(0, 120);
      const labelOf = el => {
        const aria = el.getAttribute("aria-label");
        if (aria) return clean(aria);
        if (el.labels && el.labels.length) return clean(el.labels[0].innerText);
        const by = el.getAttribute("aria-labelledby");
        if (by) { const l = document.getElementById(by); if (l) return clean(l.innerText); }
        if (el.tagName === "SELECT") return clean(el.name || el.title || "");
        return clean(el.innerText || el.value && el.type !== "password" && el.value || el.placeholder || el.title || el.alt || el.name || (el.querySelector("img") || {}).alt || "");
      };
      const roleOf = el => {
        const role = el.getAttribute("role");
        if (role) return role;
        const tag = el.tagName.toLowerCase();
        if (tag === "a") return "link";
        if (tag === "button" || tag === "summary") return "button";
        if (tag === "select") return "select";
        if (tag === "textarea") return "textbox";
        if (tag === "input") {
          const t = (el.type || "text").toLowerCase();
          if (["button", "submit", "reset", "image"].includes(t)) return "button";
          if (["checkbox", "radio"].includes(t)) return t;
          return t === "text" ? "textbox" : t + " field";
        }
        if (el.isContentEditable) return "textbox";
        return "clickable";
      };
      document.querySelectorAll("[data-dante-ref]").forEach(el => el.removeAttribute("data-dante-ref"));
      const selector = "a[href], button, input:not([type=hidden]), select, textarea, summary, [role=button], [role=link], [role=tab], [role=menuitem], [role=checkbox], [role=switch], [contenteditable=true], [onclick]";
      const controls = [];
      let n = 0;
      for (const el of document.querySelectorAll(selector)) {
        if (!visible(el)) continue;
        n += 1;
        el.setAttribute("data-dante-ref", String(n));
        const c = { ref: n, role: roleOf(el), label: labelOf(el) };
        if (el.tagName === "A") c.href = el.getAttribute("href");
        if (el.type === "password") c.value = el.value ? "••••" : "";
        else if (el.type === "checkbox" || el.type === "radio") c.value = el.checked ? "checked" : "unchecked";
        else if (el.tagName === "SELECT") c.value = (el.selectedOptions[0] || {}).text || "";
        else if ("value" in el && el.tagName !== "BUTTON" && el.tagName !== "A") c.value = String(el.value || "").slice(0, 120);
        if (el.disabled) c.disabled = true;
        controls.push(c);
      }
      return JSON.stringify({
        url: location.href, title: document.title, text: (document.body ? document.body.innerText : "").replace(/\n{3,}/g, "\n\n").trim(),
        controls, errors: d.errors, requests: d.requests, width: innerWidth, height: innerHeight
      });
    })();
    """#

    /// Clicks the control numbered `ref`; returns "ok" or why not.
    public static func click(_ ref: Int) -> String {
        """
        (() => {
          const el = document.querySelector('[data-dante-ref="\(ref)"]');
          if (!el) return "No control \(ref) on this page; read the page again for fresh numbers.";
          if (el.disabled) return "Control \(ref) is disabled.";
          el.scrollIntoView({ block: "center" });
          el.focus && el.focus();
          el.click();
          return "ok";
        })();
        """
    }

    /// Types into the control numbered `ref` the way a framework notices (the native setter,
    /// then input and change events); `submit` presses Return or submits its form.
    public static func type(_ ref: Int, text: String, submit: Bool) -> String {
        let quoted = (try? String(decoding: JSONEncoder().encode(text), as: UTF8.self)) ?? "\"\""
        return """
        (() => {
          const el = document.querySelector('[data-dante-ref="\(ref)"]');
          if (!el) return "No control \(ref) on this page; read the page again for fresh numbers.";
          const text = \(quoted);
          el.scrollIntoView({ block: "center" });
          el.focus();
          if (el.tagName === "SELECT") {
            const option = Array.from(el.options).find(o => o.text.trim() === text || o.value === text);
            if (!option) return "No option “" + text + "” in control \(ref).";
            el.value = option.value;
          } else if (el.isContentEditable) {
            el.textContent = text;
          } else {
            const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(proto, "value").set.call(el, text);
          }
          el.dispatchEvent(new Event("input", { bubbles: true }));
          el.dispatchEvent(new Event("change", { bubbles: true }));
          if (\(submit ? "true" : "false")) {
            const keys = { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true };
            const go = el.dispatchEvent(new KeyboardEvent("keydown", keys));
            el.dispatchEvent(new KeyboardEvent("keyup", keys));
            if (go && el.form) el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit();
          }
          return "ok";
        })();
        """
    }

    public static let pageHeight = "Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)"
}

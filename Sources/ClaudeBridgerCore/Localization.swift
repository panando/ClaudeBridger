import Foundation

/// Which language the interface is drawn in.
public enum InterfaceStrings {

    public static func isChinese(_ language: InterfaceLanguage) -> Bool {
        switch language {
        case .simplifiedChinese: return true
        case .english: return false
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("zh")
        }
    }

    /// Picks between a Chinese and an English string.
    public static func pick(_ language: InterfaceLanguage, zh: String, en: String) -> String {
        isChinese(language) ? zh : en
    }
}

/// User-facing text, in one place.
///
/// The app ships bilingual because its subject matter is bilingual: the vendors are Chinese and
/// their documentation is Chinese, while the tool it configures is documented in English. Writing
/// the strings here rather than inline keeps the two versions from drifting.
public enum L {

    public static func appTagline(_ language: InterfaceLanguage) -> String {
        InterfaceStrings.pick(
            language,
            zh: "把 Claude Code 接到任何 Anthropic 兼容的模型服务，不用手改配置文件。",
            en: "Point Claude Code at any Anthropic-compatible model service, without hand-editing config files."
        )
    }

    public static func profiles(_ language: InterfaceLanguage) -> String {
        InterfaceStrings.pick(language, zh: "后端", en: "Backends")
    }

    public static func newProfile(_ language: InterfaceLanguage) -> String {
        InterfaceStrings.pick(language, zh: "新建后端", en: "New backend")
    }

    public static func save(_ language: InterfaceLanguage) -> String {
        InterfaceStrings.pick(language, zh: "保存", en: "Save")
    }

    public static func activate(_ language: InterfaceLanguage) -> String {
        InterfaceStrings.pick(language, zh: "启用", en: "Activate")
    }

    public static func delete(_ language: InterfaceLanguage) -> String {
        InterfaceStrings.pick(language, zh: "删除", en: "Delete")
    }

    public static func settings(_ language: InterfaceLanguage) -> String {
        InterfaceStrings.pick(language, zh: "设置", en: "Settings")
    }

    public static func cancel(_ language: InterfaceLanguage) -> String {
        InterfaceStrings.pick(language, zh: "取消", en: "Cancel")
    }

    public static func restoreOfficial(_ language: InterfaceLanguage) -> String {
        InterfaceStrings.pick(language, zh: "恢复官方配置", en: "Restore official config")
    }

    public static func name(_ language: InterfaceLanguage) -> String {
        InterfaceStrings.pick(language, zh: "名称", en: "Name")
    }

    public static func baseURL(_ language: InterfaceLanguage) -> String {
        InterfaceStrings.pick(language, zh: "Base URL", en: "Base URL")
    }

    public static func credential(_ language: InterfaceLanguage) -> String {
        InterfaceStrings.pick(language, zh: "API 凭据", en: "API credential")
    }

    public static func credentialMode(_ language: InterfaceLanguage) -> String {
        InterfaceStrings.pick(language, zh: "凭据方式", en: "Credential header")
    }

    public static func models(_ language: InterfaceLanguage) -> String {
        InterfaceStrings.pick(language, zh: "模型", en: "Models")
    }

    public static func contextWindow(_ language: InterfaceLanguage) -> String {
        InterfaceStrings.pick(language, zh: "上下文窗口", en: "Context window")
    }

    public static func advanced(_ language: InterfaceLanguage) -> String {
        InterfaceStrings.pick(language, zh: "高级", en: "Advanced")
    }

    public static func notActivated(_ language: InterfaceLanguage) -> String {
        InterfaceStrings.pick(language, zh: "还没接入", en: "Not connected")
    }

    public static func active(_ language: InterfaceLanguage) -> String {
        InterfaceStrings.pick(language, zh: "使用中", en: "Active")
    }

    public static func onlyManagedKeys(_ language: InterfaceLanguage) -> String {
        InterfaceStrings.pick(
            language,
            zh: "只改 settings.json 里 env 下属于 Claude Code 接线的那些键，你自己的变量原样保留。",
            en: "Only the env keys that wire up Claude Code are touched; your own variables are left as they are."
        )
    }
}

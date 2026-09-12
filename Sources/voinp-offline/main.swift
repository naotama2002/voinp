import VoinpEngine
import VoinpUIKit

// オフライン版: VoinpNet / VoinpProviders に依存していないため、
// 送信コードがバイナリに存在しない。
let loaded = ConfigStore().load()
VoinpRoot.run(Dependencies(settings: loaded.settings, configError: loaded.error))

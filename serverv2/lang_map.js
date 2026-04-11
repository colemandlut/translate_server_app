// V2 language codes mapping: BCP-47 -> V2 STT code
const V2_LANG_MAP = {
  'zh-CN': 'cmn-Hans-CN',
  'zh-TW': 'cmn-Hant-TW',
  'en-US': 'en-US',
  'ja-JP': 'ja-JP',
  'ko-KR': 'ko-KR',
  'fr-FR': 'fr-FR',
  'de-DE': 'de-DE',
  'es-ES': 'es-ES',
  'pt-BR': 'pt-BR',
  'ru-RU': 'ru-RU',
  'ar-SA': 'ar-SA',
  'hi-IN': 'hi-IN',
  'th-TH': 'th-TH',
  'vi-VN': 'vi-VN',
  'it-IT': 'it-IT',
};

const LANG_NAMES = {
  'zh-cn': '中文 (简体)', 'zh-tw': '中文 (繁體)', 'en-us': 'English',
  'ja-jp': '日本語', 'ko-kr': '한국어', 'fr-fr': 'Français',
  'de-de': 'Deutsch', 'es-es': 'Español', 'pt-br': 'Português',
  'ru-ru': 'Русский', 'ar-sa': 'العربية', 'hi-in': 'हिन्दी',
  'th-th': 'ไทย', 'vi-vn': 'Tiếng Việt', 'it-it': 'Italiano',
  'cmn-hans-cn': '中文 (简体)', 'cmn-hant-tw': '中文 (繁體)',
};

function toV2Lang(bcp47) { return V2_LANG_MAP[bcp47] || bcp47; }
function langName(c) { return LANG_NAMES[c.toLowerCase()] || c; }
function transCode(c) { return c.toLowerCase() === 'zh-tw' ? 'zh-TW' : c.split('-')[0]; }

module.exports = { toV2Lang, langName, transCode, LANG_NAMES };

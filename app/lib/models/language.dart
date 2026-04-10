class Language {
  final String code;
  final String name;

  const Language({required this.code, required this.name});
}

const languages = [
  Language(code: 'zh-CN', name: '中文 (简体)'),
  Language(code: 'zh-TW', name: '中文 (繁體)'),
  Language(code: 'en-US', name: 'English'),
  Language(code: 'ja-JP', name: '日本語'),
  Language(code: 'ko-KR', name: '한국어'),
  Language(code: 'fr-FR', name: 'Français'),
  Language(code: 'de-DE', name: 'Deutsch'),
  Language(code: 'es-ES', name: 'Español'),
  Language(code: 'pt-BR', name: 'Português'),
  Language(code: 'ru-RU', name: 'Русский'),
  Language(code: 'ar-SA', name: 'العربية'),
  Language(code: 'hi-IN', name: 'हिन्दी'),
  Language(code: 'th-TH', name: 'ไทย'),
  Language(code: 'vi-VN', name: 'Tiếng Việt'),
  Language(code: 'it-IT', name: 'Italiano'),
];

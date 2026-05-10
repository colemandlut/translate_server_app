class Language {
  final String code;
  final String name;

  const Language({required this.code, required this.name});
}

const languages = [
  Language(code: 'zh-CN', name: '汉语'),
  Language(code: 'en-US', name: 'English'),
  Language(code: 'ja-JP', name: '日本語'),
];

import Foundation
import SwiftUI

struct Prompt: Identifiable {
  let id = UUID()
  let title: String
  let systemPrompt: String
  let iconName: String
  let maxTokens: Int
  let iconTint: Color
  let iconBackground: Color
}

extension Prompt {
  // Editable text: rewrite actions
  static let editableDefaults: [Prompt] = [
    Prompt(
      title: "Fix the text",
      systemPrompt: """
        Edit the following text to:
        - Remove filler words and unnecessary repetition
        - Auto-correct grammar and spelling errors
        - Improve clarity and formatting
        Return only the edited text, no explanation.
        """,
      iconName: "fix_text",
      maxTokens: 400,
      iconTint: Color(red: 52/255, green: 211/255, blue: 153/255),
      iconBackground: Color(red: 52/255, green: 211/255, blue: 153/255).opacity(0.15)
    ),
    Prompt(
      title: "Make it formal",
      systemPrompt: "Rewrite the following text in a more formal, professional tone. Return only the rewritten text, no explanation.",
      iconName: "make_formal",
      maxTokens: 300,
      iconTint: Color(red: 251/255, green: 191/255, blue: 36/255),
      iconBackground: Color(red: 251/255, green: 191/255, blue: 36/255).opacity(0.12)
    ),
    Prompt(
      title: "Translate",
      systemPrompt: """
        Detect the language of the following text.
        - If it is Chinese (Traditional or Simplified), translate it to English.
        - If it is English or any other language, translate it to Traditional Chinese.
        Return only the translation, no explanation.
        """,
      iconName: "translate",
      maxTokens: 400,
      iconTint: Color(red: 167/255, green: 139/255, blue: 250/255),
      iconBackground: Color(red: 167/255, green: 139/255, blue: 250/255).opacity(0.15)
    ),
  ]

  // Read-only text: analysis actions
  static let nonEditableDefaults: [Prompt] = [
    Prompt(
      title: "Summarize",
      systemPrompt: "Summarize the key points of the following text in bullet points. Be concise.",
      iconName: "summarize",
      maxTokens: 500,
      iconTint: Color(red: 96/255, green: 165/255, blue: 250/255),
      iconBackground: Color(red: 96/255, green: 165/255, blue: 250/255).opacity(0.15)
    ),
    Prompt(
      title: "Explain this",
      systemPrompt: "Explain the following text in simple, plain language as if explaining to someone unfamiliar with the topic.",
      iconName: "explain",
      maxTokens: 500,
      iconTint: Color(red: 34/255, green: 211/255, blue: 238/255),
      iconBackground: Color(red: 34/255, green: 211/255, blue: 238/255).opacity(0.15)
    ),
    Prompt(
      title: "Translate",
      systemPrompt: """
        Detect the language of the following text.
        - If it is Chinese (Traditional or Simplified), translate it to English.
        - If it is English or any other language, translate it to Traditional Chinese.
        Return only the translation, no explanation.
        """,
      iconName: "translate",
      maxTokens: 400,
      iconTint: Color(red: 167/255, green: 139/255, blue: 250/255),
      iconBackground: Color(red: 167/255, green: 139/255, blue: 250/255).opacity(0.15)
    ),
    Prompt(
      title: "List action items",
      systemPrompt: "Extract all action items, tasks, and to-dos from the following text. Format as a bullet list.",
      iconName: "list-actions",
      maxTokens: 300,
      iconTint: Color(red: 251/255, green: 146/255, blue: 60/255),
      iconBackground: Color(red: 251/255, green: 146/255, blue: 60/255).opacity(0.12)
    ),
  ]

  // Screenshot / Vision prompts
  static let screenshotDefaults: [Prompt] = [
    Prompt(
      title: "Extract text",
      systemPrompt: "Extract all visible text from this screenshot exactly as it appears, preserving structure and line breaks.",
      iconName: "fix_text",
      maxTokens: 800,
      iconTint: Color(red: 52/255, green: 211/255, blue: 153/255),
      iconBackground: Color(red: 52/255, green: 211/255, blue: 153/255).opacity(0.15)
    ),
    Prompt(
      title: "Describe this",
      systemPrompt: "Describe what you see in this screenshot concisely. Include layout, content, and any key information.",
      iconName: "explain",
      maxTokens: 500,
      iconTint: Color(red: 34/255, green: 211/255, blue: 238/255),
      iconBackground: Color(red: 34/255, green: 211/255, blue: 238/255).opacity(0.15)
    ),
    Prompt(
      title: "Summarize",
      systemPrompt: "Summarize the key information visible in this screenshot in bullet points.",
      iconName: "summarize",
      maxTokens: 400,
      iconTint: Color(red: 96/255, green: 165/255, blue: 250/255),
      iconBackground: Color(red: 96/255, green: 165/255, blue: 250/255).opacity(0.15)
    ),
    Prompt(
      title: "Translate",
      systemPrompt: "Detect the language of the text in this screenshot. If Chinese, translate to English. If English or other, translate to Traditional Chinese. Return only the translation.",
      iconName: "translate",
      maxTokens: 600,
      iconTint: Color(red: 167/255, green: 139/255, blue: 250/255),
      iconBackground: Color(red: 167/255, green: 139/255, blue: 250/255).opacity(0.15)
    ),
  ]
}

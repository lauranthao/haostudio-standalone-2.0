// HAo Studio 2.0 — VOD danmaku API settings (b36 item 11).
//
// One page: danmaku API address + access token. The address is
// the danmu-api host the VOD player fetches from; the token is
// the optional first path segment of the hop-1 URL
// (`<address>/<TOKEN>/api/v2/...`) — never a header, never a
// query key, never shown on the settings list page.
//
// Save is explicit and local-only: the drafts are validated
// here (format only, no network probe) and written to
// UserDefaults through `VodDanmakuApiConfig`. A failed check
// keeps the old stored values and shows one inline red reason
// — no alert, no toast, no leaving the page. Leaving without
// saving discards the drafts. "恢复默认" clears both fields
// and saves immediately (empty = official host).
//
// No live-danmaku key is read or written here (`hao_danmaku_*`
// belongs to the live room); no font size / speed / stroke /
// area / colour rows — VOD danmaku has fixed rendering.

import SwiftUI

struct VodDanmakuApiSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.haoTheme) private var theme

    @State private var apiUrlDraft = ""
    @State private var apiTokenDraft = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                TextField("地址，如 https://example.com", text: $apiUrlDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } header: {
                Text("弹幕 API 地址")
            } footer: {
                Text("留空使用官方地址；下次打开影片时生效。")
            }
            Section {
                TextField("访问密钥", text: $apiTokenDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("访问密钥")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("自托管服务设了访问密钥才填；官方地址不用填。密钥放在地址后面发送，不会出现在弹幕请求头里。")
                    if !apiTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       apiUrlDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("地址留空时，密钥将用在官方地址上；官方地址使用默认密钥，自定义密钥可能导致无弹幕。")
                    }
                }
            }
            Section {
                Button("保存") {
                    if let error = VodDanmakuApiConfig.validationError(apiUrl: apiUrlDraft, apiToken: apiTokenDraft) {
                        errorMessage = error
                    } else {
                        VodDanmakuApiConfig(apiUrl: apiUrlDraft, apiToken: apiTokenDraft).save()
                        errorMessage = nil
                        dismiss()
                    }
                }
                .font(.haoBody)
                .foregroundStyle(theme.accentText)
                Button("恢复默认") {
                    apiUrlDraft = ""
                    apiTokenDraft = ""
                    errorMessage = nil
                    VodDanmakuApiConfig().save()
                }
                .font(.haoBody)
                .foregroundStyle(theme.accentText)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.haoFootnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .haoBottomChromePadding()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.scaffoldBackground)
        .navigationTitle("影视弹幕 API")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let config = VodDanmakuApiConfig.load()
            apiUrlDraft = config.apiUrl
            apiTokenDraft = config.apiToken
        }
    }
}

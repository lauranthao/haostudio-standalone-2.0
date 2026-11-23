// HAo Studio 2.0 — Emby connection page (S5-B leg).
//
// Server address + account + password (memory only) + API key
// (advanced, for key-only direct connection). The view model
// (EmbyConfigViewModel, A leg) owns the stored config, the test
// probe and the save/clear writes; this view only renders the
// form and the status line.
//
// Credentials are never logged, never written to a file by this
// view, and never appear in tests. The password is kept in the
// view-model memory only; the API key / token goes to the
// Keychain through the store, never to the JSON file.

import SwiftUI

struct EmbyConfigView: View {
    @StateObject private var viewModel = EmbyConfigViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.haoTheme) private var theme

    @State private var showingClearAlert = false
    @State private var showingSaveFailedAlert = false

    var body: some View {
        List {
            Section {
                TextField("服务器地址，如 https://emby.example.com:8096", text: $viewModel.baseUrl)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("账号", text: $viewModel.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $viewModel.password)
            } header: {
                Text("服务器")
            } footer: {
                Text("密码只用于本次登录换取令牌，不会保存。")
            }
            Section {
                DisclosureGroup("高级选项") {
                    SecureField("API key", text: $viewModel.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("免密直连用，有账号登录时不用填。")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textMuted)
                }
            }
            Section {
                statusRow
                Button("测试连接") {
                    viewModel.testConnection { _ in
                    }
                }
                .font(.system(size: 15))
                Button("保存") {
                    if viewModel.save() {
                        dismiss()
                    } else {
                        showingSaveFailedAlert = true
                    }
                }
                .font(.system(size: 15))
                Button("清除配置", role: .destructive) {
                    showingClearAlert = true
                }
                .font(.system(size: 15))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.scaffoldBackground)
        .navigationTitle("Emby 连接")
        .navigationBarTitleDisplayMode(.inline)
        .alert("清除配置", isPresented: $showingClearAlert) {
            Button("取消", role: .cancel) {
            }
            Button("清除", role: .destructive) {
                viewModel.clear()
            }
        } message: {
            Text("将清除服务器地址、账号与已保存的令牌，之后需要重新配置。")
        }
        .alert("保存失败", isPresented: $showingSaveFailedAlert) {
            Button("好", role: .cancel) {
            }
        } message: {
            Text("配置没有保存成功，请检查服务器地址后重试。")
        }
    }

    private var statusRow: some View {
        HStack {
            Text("状态")
                .font(.system(size: 15))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Text(statusText)
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var statusText: String {
        switch viewModel.status {
        case .unconfigured:
            return "未配置"
        case .configured(let serverName, let version):
            if serverName.isEmpty && version.isEmpty {
                return "已配置"
            }
            if version.isEmpty {
                return serverName
            }
            return "\(serverName) \(version)"
        case .testing:
            return "测试中…"
        case .failed(let message):
            return message.isEmpty ? "连接失败" : message
        }
    }
}

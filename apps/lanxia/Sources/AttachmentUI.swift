import AppKit
import SwiftUI

struct AttachmentTrayView: View {
    @ObservedObject var store: AttachmentStore
    let disabled: Bool
    @State private var selected: ChatAttachment?

    var body: some View {
        VStack(spacing: 5) {
            ForEach(store.items) { item in
                HStack(spacing: 7) {
                    DwellButton(target: "预览附件 \(item.name)", action: { selected = item }) {
                        HStack(spacing: 7) {
                            if let url = item.imageURL, let image = NSImage(contentsOf: url) {
                                Image(nsImage: image).resizable().scaledToFit().frame(width: 26, height: 26)
                            } else { Image(systemName: "doc.text").frame(width: 26) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.system(size: 10, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                                    .stashHighlightedText()
                                Text(item.notice ?? "已读取，点击预览").font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "eye").font(.system(size: 9)).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("预览附件 \(item.name)")
                    Button { store.remove(id: item.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                        .buttonStyle(.plain).disabled(disabled).accessibilityLabel("移除附件 \(item.name)")
                }.padding(7).stashGlassSurface(cornerRadius: 8)
            }
        }
        .sheet(item: $selected) { item in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        .stashHighlightedText()
                    Spacer()
                    DwellButton(target: "关闭附件预览", action: { selected = nil }) { Text("关闭") }
                        .font(.system(size: 11))
                }
                Text(item.notice ?? "已读取文件内容").font(.system(size: 10)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let url = item.imageURL, let image = NSImage(contentsOf: url) {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 150)
                        }
                        Text(item.extractedText.isEmpty ? "未提取到文字；在线模式可继续理解图片。" : item.extractedText)
                            .font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding(16).frame(width: 330, height: 370)
        }
    }
}

import SwiftUI

struct MaintenanceGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Mac 保养须知", systemImage: "questionmark.circle.fill")
                .font(.headline)

            Group {
                tip(
                    icon: "wind",
                    title: "先改善散热环境",
                    text: "把 Mac 放在坚硬、平整、通风的表面，避免床铺、沙发和阳光直晒；保持进出风口畅通。炎热环境下可降低室温，并暂时减轻高负载任务。"
                )
                tip(
                    icon: "chart.line.downtrend.xyaxis",
                    title: "检查持续高负载",
                    text: "如果温度持续偏高，查看活动监视器中的 CPU 占用，关闭不需要的高负载程序和多余标签页。短暂温度升高可能是正常现象，关注持续趋势和异常噪声。"
                )
                tip(
                    icon: "fan",
                    title: "风扇与内部清洁",
                    text: "灰尘可能堵塞风道。拆机清洁前先关机、拔掉电源；不熟悉内部结构时交给可信维修人员。使用压缩空气时不要让风扇自由高速旋转，也不要把液体或清洁剂喷入机身。"
                )
                tip(
                    icon: "battery.100",
                    title: "留意电池异常",
                    text: "若机身或触控板被顶起、外壳变形、出现异味或异常发热，可能是电池膨胀或故障。停止使用和充电，不要挤压或自行刺穿电池，尽快联系专业维修。"
                )
            }

            Text("提高风扇转速不能替代清洁、维修或系统热保护；本工具不提供温度安全保证。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 340)
    }

    private func tip(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

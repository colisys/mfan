import SwiftUI

/// Form for a new rule: trigger kind, process or temperature, target fan and strength.
struct RuleComposer: View {
    let fans: [RuleFanRange]
    let add: (String, Int, Int?, Int?) -> Void

    @State private var temperatureOnly = false
    @State private var name = ""
    @State private var usesTemp = false
    @State private var temp = Double(RuleTemperature.defaultCelsius)
    @State private var fan: Int?
    @State private var percent = 50.0
    @State private var candidates: [String] = []

    private let percentStep = 5.0

    private var snappedPercent: Int {
        Int(min(100, max(percentStep, (percent / percentStep).rounded() * percentStep)))
    }

    private var canAdd: Bool {
        temperatureOnly || !ProcessRuleResolver.normalized(name).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("新建规则").font(.title3.weight(.semibold))
                Text("同一进程和风扇只保留一条，重复添加会更新原规则。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Picker("触发方式", selection: $temperatureOnly) {
                Text("应用/进程").tag(false)
                Text("仅温度").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if !temperatureOnly {
                field("进程或 App") {
                    HStack(spacing: 6) {
                        TextField("例如 UTM", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(commit)
                        Menu {
                            if candidates.isEmpty { Text("未找到运行中的 App") }
                            ForEach(candidates, id: \.self) { candidate in
                                Button(candidate) { name = candidate }
                            }
                            Divider()
                            Button("刷新列表") { reloadCandidates() }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("从运行中的 App 选择")
                    }
                }
                Toggle("自定义起始温度（默认 40°C）", isOn: $usesTemp)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }

            if temperatureOnly || usesTemp {
                field("起始温度") {
                    HStack(spacing: 8) {
                        Slider(
                            value: $temp,
                            in: Double(RuleTemperature.range.lowerBound)...Double(RuleTemperature.range.upperBound),
                            step: Double(RuleTemperature.step)
                        )
                        Text("\(Int(temp))°C")
                            .font(.callout.monospacedDigit())
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }

            field("作用于") {
                Picker("作用风扇", selection: $fan) {
                    Text("全部风扇").tag(Int?.none)
                    ForEach(fans) { item in
                        Text("风扇 #\(item.id)").tag(Int?.some(item.id))
                    }
                }
                .labelsHidden()
            }

            field("高温目标") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Slider(value: $percent, in: percentStep...100, step: percentStep)
                        Text("\(snappedPercent)%")
                            .font(.callout.monospacedDigit())
                            .frame(width: 48, alignment: .trailing)
                    }
                    if !fans.isEmpty {
                        Text("各风扇自身范围的 \(snappedPercent)%："
                             + ProcessRulesSection.preview(
                                percent: snappedPercent,
                                fans: ProcessRulesSection.applicableFans(for: fan, in: fans)))
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: 0)

            Button(action: commit) {
                Label("添加规则", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canAdd)
        }
        .onAppear(perform: reloadCandidates)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }

    private func commit() {
        guard canAdd else { return }
        let hasTemp = temperatureOnly || usesTemp
        add(
            temperatureOnly ? "" : name.trimmingCharacters(in: .whitespacesAndNewlines),
            snappedPercent, fan, hasTemp ? Int(temp) : nil
        )
        name = ""
    }

    private func reloadCandidates() {
        Task {
            let names = await Task.detached(priority: .utility) { ProcessScanner.runningAppNames() }.value
            candidates = names
        }
    }
}

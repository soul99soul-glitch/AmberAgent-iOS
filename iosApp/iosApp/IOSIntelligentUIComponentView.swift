import SwiftUI
import Charts

@MainActor
struct IOSIntelligentUIComponentView: View {
    let component: IOSIntelligentUIComponent
    @Binding var draftValues: [String: String]
    var isEnabled: Bool
    var canSubmit: Bool = true
    var fieldLabels: [String: String] = [:]
    var fieldComponents: [String: IOSIntelligentUIComponent] = [:]
    var requiredFieldIDs: Set<String> = []
    var onSubmit: () -> Void
    var onReset: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var title: String {
        let label = component.title ?? component.fieldID.flatMap { fieldLabels[$0] } ?? ""
        return component.fieldID.map { requiredFieldIDs.contains($0) } == true ? label + "（必填）" : label
    }
    private var text: String { component.text ?? "" }
    private var children: [IOSIntelligentUIComponent] { component.children ?? [] }
    private var items: [String] { component.items ?? [] }
    private var rows: [IOSIntelligentUIComponent.Row] { component.rows ?? [] }
    private var resolvedNumber: Double? {
        IOSIntelligentUIComponentValues.resolveNumber(value: component.value, valueFieldID: component.valueFieldID,
                                                       draftValues: draftValues, fieldComponents: fieldComponents)
    }
    private var displayedInputNumber: Double? {
        IOSIntelligentUIComponentValues.numericValue(stringBinding.wrappedValue, input: component)
    }
    private func numericStatus(fieldID: String?) -> String? {
        guard let fieldID else { return nil }
        let raw = draftValues[fieldID] ?? ""
        guard let owner = fieldComponents[fieldID] else { return "尚未填写" }
        let number = IOSIntelligentUIComponentValues.numericValue(raw, input: owner)
        if raw.isEmpty { return number == nil ? "尚未填写" : "预览值，尚未确认" }
        return number == nil ? "数值不合法" : nil
    }
    private func rowNumber(_ row: IOSIntelligentUIComponent.Row) -> Double? {
        IOSIntelligentUIComponentValues.resolveNumber(value: row.value, valueFieldID: row.valueFieldID,
                                                       draftValues: draftValues, fieldComponents: fieldComponents)
    }
    private var options: [IOSIntelligentUIComponent.Option] { component.options ?? [] }
    private var spacing: CGFloat { CGFloat(component.style?.spacing?.points ?? (component.style?.density == .compact ? 6 : 12)) }
    private var leading: HorizontalAlignment { component.style?.alignment == .center ? .center : .leading }
    private var frameAlignment: Alignment { component.style?.alignment == .center ? .center : .leading }
    private var tone: Color {
        switch component.style?.tone ?? .accent {
        case .neutral: AmberTheme.foreground2
        case .accent: AmberTheme.accent
        case .success: AmberTheme.accentGreen
        case .warning: AmberTheme.statusAmber
        case .danger: AmberTheme.accentRed
        }
    }

    private var filledInk: Color {
        switch component.style?.tone ?? .accent {
        case .accent: AmberTheme.accentInk
        case .danger: .white
        case .neutral, .success, .warning: .black
        }
    }

    private var isFilled: Bool { component.style?.emphasis == .filled }
    private var effectiveInk: Color { isFilled ? filledInk : AmberTheme.foreground }
    private var secondaryInk: Color { isFilled ? filledInk.opacity(0.85) : AmberTheme.foreground2 }
    private var mutedInk: Color { isFilled ? filledInk.opacity(0.75) : AmberTheme.muted }
    private var muted2Ink: Color { isFilled ? filledInk.opacity(0.65) : AmberTheme.muted2 }
    private var effectiveAccentInk: Color { isFilled ? filledInk : tone }
    private var componentSurface: Color { isFilled ? filledInk.opacity(0.06) : AmberTheme.surface }
    private var componentSurface2: Color { isFilled ? filledInk.opacity(0.1) : AmberTheme.surface2 }
    private var componentBorder: Color { isFilled ? filledInk.opacity(0.4) : AmberTheme.border }
    private var componentBorderSoft: Color { isFilled ? filledInk.opacity(0.2) : AmberTheme.borderSoft }
    private var selectionBackground: Color { isFilled ? filledInk.opacity(0.12) : AmberTheme.accentTint }

    var body: some View {
        content
            .padding(CGFloat(component.style?.padding?.points ?? 0))
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .background(styleBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                if component.style?.emphasis == .outlined {
                    RoundedRectangle(cornerRadius: 12).stroke(tone.opacity(0.5), lineWidth: 1)
                }
            }
            .foregroundStyle(component.style?.emphasis == .filled ? filledInk : AmberTheme.foreground)
            .tint(effectiveAccentInk)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("task-ui-component-\(component.id)")
    }

    private var styleBackground: Color {
        switch component.style?.emphasis ?? .plain {
        case .plain, .outlined: .clear
        case .soft: tone.opacity(0.1)
        case .filled: tone
        }
    }

    @ViewBuilder private var content: some View {
        switch component.kind.family {
        case "layout": layoutContent
        case "text": textContent
        case "status": statusContent
        case "input": inputContent
        case "data": dataContent
        case "media": mediaContent
        case "task": taskContent
        default: actionContent
        }
    }

    private func child(_ node: IOSIntelligentUIComponent) -> IOSIntelligentUIComponentView {
        IOSIntelligentUIComponentView(component: node, draftValues: $draftValues, isEnabled: isEnabled,
                                      canSubmit: canSubmit, fieldLabels: fieldLabels, fieldComponents: fieldComponents, requiredFieldIDs: requiredFieldIDs, onSubmit: onSubmit, onReset: onReset)
    }

    private var childColumn: some View {
        VStack(alignment: leading, spacing: spacing) { ForEach(children) { child($0) } }
    }

    private var adaptiveColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize { return [GridItem(.flexible())] }
        if let columns = component.columns {
            return Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .topLeading), count: columns)
        }
        return [GridItem(.adaptive(minimum: 140), spacing: spacing, alignment: .topLeading)]
    }

    @ViewBuilder private var layoutContent: some View {
        switch component.kind {
        case .stack: ZStack(alignment: frameAlignment) { ForEach(children) { child($0) } }
        case .column: childColumn
        case .row:
            if dynamicTypeSize.isAccessibilitySize { childColumn }
            else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(children) { child($0).fixedSize(horizontal: true, vertical: false) }
                    }
                    childColumn
                }
            }
        case .grid: LazyVGrid(columns: adaptiveColumns, alignment: leading, spacing: spacing) { ForEach(children) { child($0) } }
        case .card:
            childColumn.padding(14).background(componentSurface, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(componentBorderSoft, lineWidth: 1) }
        case .panel:
            VStack(alignment: .leading, spacing: spacing) {
                heading
                if !title.isEmpty { Divider() }
                childColumn
            }.padding(16).background(componentSurface2, in: RoundedRectangle(cornerRadius: 8))
        case .group: childColumn.accessibilityElement(children: .contain)
        case .inset: childColumn.padding(.horizontal, 20).padding(.vertical, 8)
        case .divider:
            HStack(spacing: 8) {
                Rectangle().fill(componentBorderSoft).frame(height: 1)
                if !title.isEmpty { Text(title).font(.caption).foregroundStyle(mutedInk).fixedSize() }
                Rectangle().fill(componentBorderSoft).frame(height: 1)
            }.padding(.vertical, 4)
        default: Spacer(minLength: CGFloat(min(max(component.value ?? 12, 0), 48))).frame(height: CGFloat(min(max(component.value ?? 12, 0), 48)))
        }
    }

    private var heading: some View {
        Group { if !title.isEmpty { Text(title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true) } }
    }

    @ViewBuilder private var textContent: some View {
        switch component.kind {
        case .title: Text(text.isEmpty ? title : text).font(.title2.weight(.bold)).fixedSize(horizontal: false, vertical: true)
        case .subtitle: Text(text.isEmpty ? title : text).font(.headline).foregroundStyle(secondaryInk)
        case .body: Text(text).font(.body).textSelection(.enabled)
        case .caption: Text(text).font(.caption).foregroundStyle(mutedInk)
        case .callout: Label(text, systemImage: component.symbol ?? "info.circle").font(.callout).padding(12).background(selectionBackground, in: RoundedRectangle(cornerRadius: 10))
        case .quote:
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(effectiveAccentInk).frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    Text(text).italic()
                    if !title.isEmpty { Text(title).font(.caption).foregroundStyle(mutedInk) }
                }
            }.fixedSize(horizontal: false, vertical: true)
        case .inlineCode: Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).padding(6).background(componentSurface2, in: RoundedRectangle(cornerRadius: 4))
        case .bulletList: itemList(numbered: false)
        case .numberedList: itemList(numbered: true)
        case .keyValue:
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title).font(.caption).foregroundStyle(mutedInk).fixedSize()
                    Text(text).font(.body).fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) { heading; Text(text) }
            }
        case .footnote: Text(text).font(.footnote).foregroundStyle(muted2Ink).padding(.top, 4)
        default: Text(text).font(.body.weight(.medium)).padding(10).background(tone.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func itemList(numbered: Bool, showHeading: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showHeading { heading }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(numbered ? "\(index + 1)." : "•").foregroundStyle(effectiveAccentInk).frame(minWidth: 18, alignment: .leading)
                    Text(item).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var statusContent: some View {
        switch component.kind {
        case .badge: Text(text.isEmpty ? title : text).font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 5).background(tone.opacity(0.14), in: Capsule())
        case .chip: Label(text.isEmpty ? title : text, systemImage: component.symbol ?? "circle.fill").font(.caption).padding(8).background(componentSurface2, in: RoundedRectangle(cornerRadius: 8))
        case .tag: Text("# " + (text.isEmpty ? title : text)).font(.caption.weight(.medium)).foregroundStyle(effectiveAccentInk).padding(6).overlay { RoundedRectangle(cornerRadius: 4).stroke(tone.opacity(0.4)) }
        case .statusDot:
            HStack(spacing: 8) { Circle().fill(effectiveAccentInk).frame(width: 8, height: 8); Text(text.isEmpty ? title : text).font(.caption) }
        case .progress:
            VStack(alignment: .leading, spacing: 6) {
                heading
                if let number = component.valueFieldID == nil ? (component.value ?? 0) : resolvedNumber {
                    ProgressView(value: min(max(number, 0), component.max ?? 100), total: component.max ?? 100)
                        .accessibilityValue("\(IOSIntelligentUIComponentValues.numericDisplayString(number)) / \(IOSIntelligentUIComponentValues.numericDisplayString(component.max ?? 100))")
                }
                if let status = numericStatus(fieldID: component.valueFieldID) { Text(status).font(.caption).foregroundStyle(mutedInk) }
                if !text.isEmpty { Text(text).font(.caption).foregroundStyle(mutedInk) }
            }
        case .stepProgress:
            VStack(alignment: .leading, spacing: 8) {
                heading
                if let number = component.valueFieldID == nil ? (component.value ?? 0) : resolvedNumber {
                    HStack(spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, _ in
                            Capsule().fill(Double(index) < number ? effectiveAccentInk : componentBorderSoft).frame(height: 5)
                        }
                    }.accessibilityElement(children: .ignore)
                        .accessibilityLabel(title)
                        .accessibilityValue("\(IOSIntelligentUIComponentValues.numericDisplayString(number)) / \(items.count)")
                }
                Text(items.joined(separator: " → ")).font(.caption).foregroundStyle(secondaryInk)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                if let status = numericStatus(fieldID: component.valueFieldID) { Text(status).font(.caption).foregroundStyle(mutedInk) }
            }
        case .skeleton:
            VStack(alignment: .leading, spacing: 8) {
                Text(title.isEmpty ? "正在准备内容" : title).font(.caption).foregroundStyle(mutedInk)
                RoundedRectangle(cornerRadius: 4).fill(componentBorderSoft).frame(height: 14)
                RoundedRectangle(cornerRadius: 4).fill(componentBorderSoft).frame(maxWidth: 180).frame(height: 14)
            }.accessibilityElement(children: .combine)
        case .emptyState:
            VStack(spacing: 8) {
                Image(systemName: component.symbol ?? "tray").font(.title).foregroundStyle(mutedInk)
                heading
                Text(text).font(.callout).foregroundStyle(mutedInk).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(20)
        case .notice: narrative(icon: component.symbol ?? "info.circle", defaultTitle: "提示", color: tone, filled: false)
        default: narrative(icon: component.symbol ?? "exclamationmark.triangle", defaultTitle: "注意", color: AmberTheme.statusAmber, filled: true)
        }
    }

    @ViewBuilder private var inputContent: some View {
        switch component.kind {
        case .singleChoice: choiceButtons()
        case .multiChoice: selectionList(checklist: false)
        case .segmented:
            VStack(alignment: .leading, spacing: 8) {
                heading
                if options.count <= 4 && options.allSatisfy({ $0.label.count <= 8 }) && !dynamicTypeSize.isAccessibilitySize {
                    Picker(title, selection: stringBinding) {
                        Text("未选").tag("")
                        ForEach(options) { Text($0.label).tag($0.id) }
                    }.pickerStyle(.segmented).frame(minHeight: 44)
                } else { choiceButtons(showHeading: false) }
            }.disabled(!isEnabled)
        case .picker:
            Picker(title, selection: stringBinding) {
                Text("请选择").tag("")
                ForEach(options) { Text($0.label).tag($0.id) }
            }.pickerStyle(.menu).frame(minHeight: 44).disabled(!isEnabled)
        case .toggle:
            if stringBinding.wrappedValue.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    heading
                    Text("尚未回答").font(.caption).foregroundStyle(mutedInk)
                    HStack(spacing: 8) {
                        Button { stringBinding.wrappedValue = "true" } label: { Text("是").foregroundStyle(effectiveInk).frame(maxWidth: .infinity, minHeight: 44) }
                            .buttonStyle(.bordered).accessibilityLabel("\(title)：是")
                        Button { stringBinding.wrappedValue = "false" } label: { Text("否").foregroundStyle(effectiveInk).frame(maxWidth: .infinity, minHeight: 44) }
                            .buttonStyle(.bordered).accessibilityLabel("\(title)：否")
                    }
                }.disabled(!isEnabled)
            } else { Toggle(title, isOn: boolBinding).frame(minHeight: 44).disabled(!isEnabled) }
        case .textField: labeledInput { TextField(component.text ?? "请输入", text: stringBinding).textFieldStyle(.roundedBorder).frame(minHeight: 44) }
        case .textArea:
            labeledInput {
                TextField(component.text ?? "请输入", text: stringBinding, axis: .vertical)
                    .lineLimit(3...8).padding(10).background(componentSurface2, in: RoundedRectangle(cornerRadius: 8))
            }
        case .numberField:
            labeledInput {
                TextField(component.text ?? "请输入数字", text: stringBinding).keyboardType(.decimalPad).textFieldStyle(.roundedBorder).frame(minHeight: 44)
                numericInputStatus
                numericDefaultConfirmation
            }
        case .slider:
            VStack(alignment: .leading, spacing: 6) {
                heading
                numericInputStatus
                if let number = displayedInputNumber {
                    Slider(value: numberBinding(initial: number), in: component.numericRange, step: component.numericStep).frame(minHeight: 44)
                    HStack { Text(IOSIntelligentUIComponentValues.numericDisplayString(component.numericRange.lowerBound)); Spacer(); Text(IOSIntelligentUIComponentValues.numericDisplayString(component.numericRange.upperBound)) }.font(.caption).foregroundStyle(mutedInk)
                } else { numericReset }
                numericDefaultConfirmation
            }.disabled(!isEnabled)
        case .stepper:
            VStack(alignment: .leading, spacing: 6) {
                if let number = displayedInputNumber {
                    Stepper(value: numberBinding(initial: number), in: component.numericRange, step: component.numericStep) {
                        VStack(alignment: .leading, spacing: 4) { heading; numericInputStatus }
                    }.frame(minHeight: 44)
                } else {
                    heading
                    numericInputStatus
                    numericReset
                }
                numericDefaultConfirmation
            }.disabled(!isEnabled)
        case .datePicker, .timePicker:
            IOSIntelligentUIDateInput(title: title, rawValue: stringBinding, timeOnly: component.kind == .timePicker, isEnabled: isEnabled, ink: effectiveInk)
        case .rating:
            VStack(alignment: .leading, spacing: 8) {
                heading
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 4) {
                    ForEach(1...Int(component.max ?? 5), id: \.self) { rating in
                        Button { stringBinding.wrappedValue = String(rating) } label: {
                            Image(systemName: rating <= (Int(displayedInputNumber ?? 0)) ? "star.fill" : "star")
                                .foregroundStyle(effectiveAccentInk).frame(minWidth: 44, minHeight: 44)
                        }.buttonStyle(.plain).accessibilityLabel("\(title)，\(rating) 分").accessibilityAddTraits(stringBinding.wrappedValue == String(rating) ? .isSelected : [])
                    }
                }
                numericInputStatus
                numericDefaultConfirmation
            }.disabled(!isEnabled)
        default:
            VStack(alignment: .leading, spacing: 8) {
                heading
                LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible(), alignment: .top)] : [GridItem(.adaptive(minimum: 80), alignment: .top)], spacing: 8) {
                    ForEach(options) { option in
                        Button { stringBinding.wrappedValue = option.id } label: {
                            VStack(spacing: 4) {
                                Circle().fill(nativeColor(option.color ?? "accent")).frame(width: 26, height: 26)
                                    .overlay { Circle().stroke(componentBorder, lineWidth: 1) }
                                Text(option.label).font(.caption).fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, minHeight: 56, alignment: .top).padding(6)
                                .background(stringBinding.wrappedValue == option.id ? selectionBackground : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityAddTraits(stringBinding.wrappedValue == option.id ? .isSelected : [])
                    }
                }
            }.disabled(!isEnabled)
        }
    }

    @ViewBuilder private var numericInputStatus: some View {
        if stringBinding.wrappedValue.isEmpty {
            if let number = displayedInputNumber {
                Text("预览值 \(IOSIntelligentUIComponentValues.numericDisplayString(number))，尚未确认").font(.caption.monospacedDigit()).foregroundStyle(secondaryInk)
            } else { Text("尚未设置").font(.caption).foregroundStyle(mutedInk) }
        } else if displayedInputNumber == nil {
            Text("数值不合法，请输入范围内的数字").font(.caption).foregroundStyle(AmberTheme.accentRed)
        } else if component.kind != .numberField, let number = displayedInputNumber {
            Text(IOSIntelligentUIComponentValues.numericDisplayString(number)).font(.caption.monospacedDigit()).foregroundStyle(secondaryInk)
        }
    }

    private var numericReset: some View {
        Button { stringBinding.wrappedValue = "" } label: {
            Text("重新设置").foregroundStyle(effectiveInk).frame(minHeight: 44)
        }.buttonStyle(.bordered)
    }

    @ViewBuilder private var numericDefaultConfirmation: some View {
        if stringBinding.wrappedValue.isEmpty, let number = displayedInputNumber {
            Button { numberBinding(initial: number).wrappedValue = number } label: {
                Text("使用当前值 \(IOSIntelligentUIComponentValues.numericDisplayString(number))").foregroundStyle(effectiveInk).frame(minHeight: 44)
            }.buttonStyle(.bordered).accessibilityLabel("\(title)：使用当前值 \(IOSIntelligentUIComponentValues.numericDisplayString(number))")
        }
    }

    private func labeledInput<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { heading; content().accessibilityLabel(title) }.disabled(!isEnabled)
    }

    private var stringBinding: Binding<String> {
        Binding(get: { draftValues[component.fieldID ?? ""] ?? "" }, set: { value in
            guard isEnabled, let fieldID = component.fieldID, draftValues[fieldID] != value else { return }
            draftValues[fieldID] = value
        })
    }

    private var boolBinding: Binding<Bool> {
        Binding(get: { stringBinding.wrappedValue == "true" }, set: { stringBinding.wrappedValue = $0 ? "true" : "false" })
    }

    private func numberBinding(initial: Double) -> Binding<Double> {
        Binding(get: { displayedInputNumber ?? initial }, set: {
            stringBinding.wrappedValue = IOSIntelligentUIComponentValues.numericDraftString($0)
        })
    }

    private func choiceButtons(showHeading: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showHeading { heading }
            ForEach(options) { option in
                Button { stringBinding.wrappedValue = option.id } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: stringBinding.wrappedValue == option.id ? "largecircle.fill.circle" : "circle").foregroundStyle(effectiveAccentInk).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.label).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                            if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(secondaryInk).fixedSize(horizontal: false, vertical: true) }
                        }
                        Spacer(minLength: 0)
                    }.padding(10).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(stringBinding.wrappedValue == option.id ? selectionBackground : componentSurface2, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).accessibilityAddTraits(stringBinding.wrappedValue == option.id ? .isSelected : [])
            }
        }.disabled(!isEnabled)
    }

    private func selectionList(checklist: Bool) -> some View {
        IOSIntelligentUISelectionList(title: title,
            options: options.isEmpty ? items.map { .init(id: $0, label: $0) } : options,
            rawValue: stringBinding, isEnabled: isEnabled, checklist: checklist, tone: effectiveAccentInk, surface: componentSurface2, secondaryInk: secondaryInk)
    }

    @ViewBuilder private var dataContent: some View {
        switch component.kind {
        case .metric:
            VStack(alignment: leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(mutedInk)
                Text(resolvedNumber.map(IOSIntelligentUIComponentValues.numericDisplayString) ?? (component.valueFieldID == nil ? text : "—")).font(.title.weight(.semibold)).monospacedDigit()
                if (component.value != nil || component.valueFieldID != nil) && !text.isEmpty { Text(text).font(.caption).foregroundStyle(secondaryInk) }
                if let status = numericStatus(fieldID: component.valueFieldID) { Text(status).font(.caption).foregroundStyle(mutedInk) }
            }.padding(12).frame(maxWidth: .infinity, alignment: frameAlignment).background(componentSurface2, in: RoundedRectangle(cornerRadius: 10))
        case .metricGrid: LazyVGrid(columns: adaptiveColumns, spacing: spacing) { ForEach(children) { child($0) } }
        case .table:
            VStack(alignment: .leading, spacing: 8) {
                heading
                ScrollView(.horizontal) {
                    Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 10) {
                        if !items.isEmpty { GridRow { ForEach(Array(items.enumerated()), id: \.offset) { _, value in Text(value).font(.caption.weight(.semibold)).frame(minWidth: 90, alignment: .leading) } } }
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            GridRow { ForEach(Array((row.cells ?? [row.label, row.detail ?? row.value?.formatted() ?? ""]).enumerated()), id: \.offset) { _, cell in Text(cell).font(.callout).frame(minWidth: 90, maxWidth: 220, alignment: .leading).fixedSize(horizontal: false, vertical: true) } }
                        }
                    }.padding(12)
                }.background(componentSurface2, in: RoundedRectangle(cornerRadius: 8))
            }
        case .list:
            VStack(alignment: .leading, spacing: 0) {
                heading.padding(.bottom, 8)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: component.symbol ?? "list.bullet").foregroundStyle(effectiveAccentInk)
                        VStack(alignment: .leading, spacing: 4) { Text(row.label); if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(mutedInk) } }
                    }.padding(.vertical, 10)
                    if index < rows.count - 1 { Divider() }
                }
            }
        case .comparison:
            VStack(alignment: .leading, spacing: 8) {
                heading
                ForEach(options) { option in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(option.label).font(.subheadline.weight(.semibold))
                        if let detail = option.detail { Text(detail).font(.callout).foregroundStyle(secondaryInk) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(componentSurface2, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        case .timeline: sequencedRows(numbered: false)
        case .steps: sequencedRows(numbered: true)
        case .checklist: selectionList(checklist: true)
        case .barChart: dataChart(line: false)
        default: dataChart(line: true)
        }
    }

    private func sequencedRows(numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading.padding(.bottom, 8)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        if numbered { Text("\(index + 1)").font(.caption.weight(.semibold)).frame(width: 26, height: 26).background(selectionBackground, in: Circle()) }
                        else { Circle().fill(effectiveAccentInk).frame(width: 9, height: 9).padding(.top, 7).frame(width: 26) }
                        if index < rows.count - 1 { Rectangle().fill(componentBorderSoft).frame(width: 1).frame(minHeight: 18) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.label).font(.body.weight(numbered ? .medium : .regular))
                        if let detail = row.detail { Text(detail).font(.callout).foregroundStyle(secondaryInk) }
                    }.padding(.bottom, 16).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }.fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func dataChart(line: Bool) -> some View {
        let points = Array(rows.enumerated()).compactMap { index, row -> (index: Int, row: IOSIntelligentUIComponent.Row, value: Double)? in
            guard let value = rowNumber(row) else { return nil }
            return (index, row, value)
        }
        return VStack(alignment: .leading, spacing: 8) {
            heading
            if points.count == rows.count {
                Chart(points, id: \.index) { point in
                    if line {
                        LineMark(x: .value("项目", point.index), y: .value("数值", point.value)).foregroundStyle(effectiveAccentInk)
                        PointMark(x: .value("项目", point.index), y: .value("数值", point.value)).foregroundStyle(effectiveAccentInk)
                    } else {
                        BarMark(x: .value("数值", point.value), y: .value("项目", point.row.label)).foregroundStyle(effectiveAccentInk)
                    }
                }.frame(height: line ? 180 : CGFloat(max(160, min(rows.count * 34, 420))))
                    .accessibilityLabel(title)
                    .accessibilityValue(points.map { "\($0.row.label)：\(IOSIntelligentUIComponentValues.numericDisplayString($0.value))" }.joined(separator: "，"))
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if let status = numericStatus(fieldID: row.valueFieldID) {
                    Text("\(row.label)：\(status)").font(.caption).foregroundStyle(mutedInk)
                }
            }
            if line {
                Text(rows.map(\.label).joined(separator: " → ")).font(.caption).foregroundStyle(mutedInk)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            }
            if !text.isEmpty { Text(text).font(.caption).foregroundStyle(mutedInk) }
        }
    }

    @ViewBuilder private var mediaContent: some View {
        switch component.kind {
        case .image: mediaImage(avatar: false)
        case .imageGrid: LazyVGrid(columns: adaptiveColumns, spacing: spacing) { ForEach(children) { child($0) } }
        case .avatar: mediaImage(avatar: true)
        case .icon: Label(text.isEmpty ? title : text, systemImage: component.symbol ?? "sparkles").font(.title3).foregroundStyle(effectiveAccentInk)
        case .linkCard:
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: "link").font(.subheadline.weight(.semibold))
                if !text.isEmpty { Text(text).font(.callout) }
                if let url = component.url { Text(url).font(.caption).foregroundStyle(mutedInk).textSelection(.enabled) }
            }.padding(12).background(componentSurface2, in: RoundedRectangle(cornerRadius: 10))
        case .fileCard:
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: component.symbol ?? "doc").font(.title2).foregroundStyle(effectiveAccentInk)
                VStack(alignment: .leading, spacing: 4) { heading; Text(text).font(.caption).foregroundStyle(mutedInk) }
            }.padding(12).background(componentSurface2, in: RoundedRectangle(cornerRadius: 10))
        case .codeBlock:
            VStack(alignment: .leading, spacing: 6) {
                heading
                ScrollView(.horizontal) { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(12).fixedSize(horizontal: true, vertical: false) }
                    .background(componentSurface2, in: RoundedRectangle(cornerRadius: 8))
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                heading
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    Text(item).font(.callout).frame(maxWidth: .infinity).padding(10).background(selectionBackground, in: RoundedRectangle(cornerRadius: 8))
                    if index < items.count - 1 { Image(systemName: "arrow.down").foregroundStyle(mutedInk).frame(maxWidth: .infinity).accessibilityHidden(true) }
                }
            }
        }
    }

    private func mediaImage(avatar: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url = component.url.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() }
                    else if phase.error != nil { Label("图片暂时无法显示", systemImage: "photo").font(.caption).foregroundStyle(mutedInk).frame(maxWidth: .infinity, minHeight: 80) }
                    else { ProgressView().frame(maxWidth: .infinity, minHeight: 80) }
                }.frame(maxWidth: avatar ? 56 : .infinity, maxHeight: avatar ? 56 : 240)
                    .clipShape(RoundedRectangle(cornerRadius: avatar ? 28 : 10))
                    .accessibilityLabel(title.isEmpty ? "图片" : title)
            } else {
                Image(systemName: component.symbol ?? (avatar ? "person.crop.circle" : "photo"))
                    .font(avatar ? .largeTitle : .title).foregroundStyle(mutedInk)
                    .frame(maxWidth: avatar ? 56 : .infinity, minHeight: avatar ? 56 : 80)
            }
            if !title.isEmpty { Text(title).font(.caption).foregroundStyle(mutedInk) }
        }
    }

    @ViewBuilder private var taskContent: some View {
        switch component.kind {
        case .goal: narrative(icon: "scope", defaultTitle: "目标", color: tone, filled: false)
        case .context: narrative(icon: "text.alignleft", defaultTitle: "背景", color: secondaryInk, filled: false)
        case .source: narrative(icon: "doc.text.magnifyingglass", defaultTitle: "来源说明", color: mutedInk, filled: false)
        case .reason: narrative(icon: "lightbulb", defaultTitle: "判断依据", color: tone, filled: false)
        case .tradeoff: narrative(icon: "arrow.left.arrow.right", defaultTitle: "取舍", color: AmberTheme.statusAmber, filled: false)
        case .result: narrative(icon: "flag", defaultTitle: "结果说明", color: tone, filled: true)
        case .assumptions:
            VStack(alignment: .leading, spacing: 8) {
                Label(title.isEmpty ? "前提假设" : title, systemImage: "questionmark.circle").font(.subheadline.weight(.semibold)).foregroundStyle(isFilled ? filledInk : AmberTheme.statusAmber)
                itemList(numbered: false, showHeading: false)
                if !text.isEmpty { Text(text).font(.caption).foregroundStyle(mutedInk) }
            }.padding(12).overlay { RoundedRectangle(cornerRadius: 8).stroke(componentBorderSoft, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
        default: IOSIntelligentUISummaryView(title: title, fieldIDs: items, fieldLabels: fieldLabels, fieldComponents: fieldComponents, values: draftValues, surface: componentSurface2, secondaryInk: secondaryInk)
        }
    }

    private func narrative(icon: String, defaultTitle: String, color: Color, filled: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(isFilled ? filledInk : color).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(title.isEmpty ? defaultTitle : title).font(.subheadline.weight(.semibold))
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(filled ? 12 : 4).background(filled ? color.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var actionContent: some View {
        switch component.kind {
        case .button, .submitButton, .resetButton:
            let isReset = component.kind == .resetButton || component.action == .reset
            Button {
                if isReset { onReset() }
                else { onSubmit() }
            } label: {
                Label(title.isEmpty ? (component.kind == .resetButton ? "重置选择" : "基于选择继续") : title,
                      systemImage: isReset ? "arrow.counterclockwise" : "arrow.up")
                    .foregroundStyle(effectiveInk)
                    .frame(maxWidth: .infinity, minHeight: 44).fixedSize(horizontal: false, vertical: true)
            }.buttonStyle(.bordered).disabled(!isEnabled || (!isReset && !canSubmit))
        case .buttonGroup:
            if dynamicTypeSize.isAccessibilitySize { childColumn }
            else { ViewThatFits(in: .horizontal) { HStack(spacing: spacing) { ForEach(children) { child($0).fixedSize(horizontal: true, vertical: false) } }; childColumn } }
        case .disclosure:
            DisclosureGroup(isExpanded: boolBinding) { childColumn.padding(.top, 8) } label: {
                Text(title).font(.subheadline.weight(.medium)).frame(minHeight: 44, alignment: .leading)
            }.disabled(!isEnabled)
        case .tabs:
            VStack(alignment: .leading, spacing: 12) {
                heading
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(children) { node in
                            Button { stringBinding.wrappedValue = node.id } label: {
                                Text(node.title ?? "").font(.callout.weight(.medium)).padding(.horizontal, 12).frame(minHeight: 44)
                                    .background(activeTabID == node.id ? selectionBackground : componentSurface2, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).accessibilityAddTraits(activeTabID == node.id ? .isSelected : []).disabled(!isEnabled)
                        }
                    }
                }
                if let node = children.first(where: { $0.id == activeTabID }) { child(node) }
            }
        case .accordion:
            IOSIntelligentUIAccordion(component: component, draftValues: $draftValues, isEnabled: isEnabled, canSubmit: canSubmit, fieldLabels: fieldLabels, fieldComponents: fieldComponents, requiredFieldIDs: requiredFieldIDs, onSubmit: onSubmit, onReset: onReset)
        default:
            Menu {
                ForEach(options) { option in Button(option.label) { stringBinding.wrappedValue = option.id } }
            } label: {
                Label(options.first(where: { $0.id == stringBinding.wrappedValue })?.label ?? (title.isEmpty ? "请选择" : title), systemImage: "chevron.down")
                    .frame(minHeight: 44).padding(.horizontal, 10).background(componentSurface2, in: RoundedRectangle(cornerRadius: 8))
            }.disabled(!isEnabled)
        }
    }

    private var activeTabID: String { children.contains(where: { $0.id == stringBinding.wrappedValue }) ? stringBinding.wrappedValue : children.first?.id ?? "" }

    private func nativeColor(_ name: String) -> Color {
        switch name {
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "cyan": .cyan
        case "blue": .blue
        case "indigo": .indigo
        case "purple": .purple
        case "pink": .pink
        case "gray": .gray
        default: AmberTheme.accent
        }
    }
}

@MainActor
private struct IOSIntelligentUISelectionList: View {
    let title: String
    let options: [IOSIntelligentUIComponent.Option]
    @Binding var rawValue: String
    let isEnabled: Bool
    let checklist: Bool
    let tone: Color
    let surface: Color
    let secondaryInk: Color
    @State private var selection = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty { Text(title).font(.subheadline.weight(.semibold)) }
            ForEach(options) { option in
                Button {
                    selection = IOSIntelligentUIComponentValues.toggling(option.id, in: selection)
                    rawValue = IOSIntelligentUIComponentValues.encodeSelection(selection)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selection.contains(option.id) ? "checkmark.square.fill" : "square").foregroundStyle(tone).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.label).strikethrough(checklist && selection.contains(option.id)).fixedSize(horizontal: false, vertical: true)
                            if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(secondaryInk).fixedSize(horizontal: false, vertical: true) }
                        }
                        Spacer(minLength: 0)
                    }.padding(checklist ? 6 : 10).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(checklist ? .clear : surface, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityAddTraits(selection.contains(option.id) ? .isSelected : []).disabled(!isEnabled)
            }
        }
        .onAppear { restore(rawValue) }
        .onChange(of: rawValue) { _, value in restore(value) }
    }

    private func restore(_ value: String) {
        let next = IOSIntelligentUIComponentValues.decodeSelection(value)
        if selection != next { selection = next }
    }
}

@MainActor
private struct IOSIntelligentUIDateInput: View {
    let title: String
    @Binding var rawValue: String
    let timeOnly: Bool
    let isEnabled: Bool
    let ink: Color
    @State private var date = Date()
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty { Text(title).font(.subheadline.weight(.semibold)) }
            if rawValue.isEmpty && !choosing {
                Button {
                    choosing = true
                    rawValue = IOSIntelligentUIComponentValues.dateString(date, timeOnly: timeOnly)
                } label: {
                    Text(timeOnly ? "选择时间" : "选择日期").foregroundStyle(ink).frame(minHeight: 44)
                }.buttonStyle(.bordered).disabled(!isEnabled).accessibilityLabel("\(title)：\(timeOnly ? "选择时间" : "选择日期")")
            } else {
                DatePicker(title, selection: Binding(get: { date }, set: { value in
                    date = value
                    rawValue = IOSIntelligentUIComponentValues.dateString(value, timeOnly: timeOnly)
                }), displayedComponents: timeOnly ? .hourAndMinute : .date)
                    .labelsHidden().frame(minHeight: 44).disabled(!isEnabled)
            }
        }
        .onAppear { restore(rawValue) }
        .onChange(of: rawValue) { _, value in restore(value) }
    }

    private func restore(_ value: String) {
        guard !value.isEmpty else { choosing = false; return }
        let next = IOSIntelligentUIComponentValues.date(from: value, timeOnly: timeOnly, fallback: date)
        if date != next { date = next }
    }
}

@MainActor
private struct IOSIntelligentUIAccordion: View {
    let component: IOSIntelligentUIComponent
    @Binding var draftValues: [String: String]
    let isEnabled: Bool
    let canSubmit: Bool
    let fieldLabels: [String: String]
    let fieldComponents: [String: IOSIntelligentUIComponent]
    let requiredFieldIDs: Set<String>
    let onSubmit: () -> Void
    let onReset: () -> Void
    @State private var expanded = Set<String>()

    private var rawValue: String { draftValues[component.fieldID ?? ""] ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(component.children ?? []) { node in
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(node.id) }, set: { open in
                    if open { expanded.insert(node.id) } else { expanded.remove(node.id) }
                    if let fieldID = component.fieldID { draftValues[fieldID] = IOSIntelligentUIComponentValues.encodeSelection(expanded) }
                })) {
                    IOSIntelligentUIComponentView(component: node, draftValues: $draftValues, isEnabled: isEnabled, canSubmit: canSubmit, fieldLabels: fieldLabels, fieldComponents: fieldComponents, requiredFieldIDs: requiredFieldIDs, onSubmit: onSubmit, onReset: onReset).padding(.top, 8)
                } label: { Text(node.title ?? "").font(.subheadline.weight(.medium)).frame(minHeight: 44, alignment: .leading) }
            }
        }.disabled(!isEnabled)
        .onAppear { restore(rawValue) }
        .onChange(of: rawValue) { _, value in restore(value) }
    }

    private func restore(_ value: String) {
        let next = IOSIntelligentUIComponentValues.decodeSelection(value)
        if expanded != next { expanded = next }
    }
}

@MainActor
private struct IOSIntelligentUISummaryView: View {
    let title: String
    let fieldIDs: [String]
    let fieldLabels: [String: String]
    let fieldComponents: [String: IOSIntelligentUIComponent]
    let values: [String: String]
    let surface: Color
    let secondaryInk: Color
    @State private var summary: [(String, String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title.isEmpty ? "当前输入摘要" : title, systemImage: "list.clipboard").font(.subheadline.weight(.semibold))
            ForEach(Array(summary.enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: 2) {
                    Text(fieldLabels[pair.0] ?? pair.0).font(.caption).foregroundStyle(secondaryInk)
                    Text(pair.1.isEmpty ? "未填写" : pair.1).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.padding(12).background(surface, in: RoundedRectangle(cornerRadius: 10))
            .onAppear { refresh() }
            .onChange(of: values) { _, _ in refresh() }
            .onChange(of: fieldIDs) { _, _ in refresh() }
            .onChange(of: fieldComponents) { _, _ in refresh() }
    }

    private func refresh() {
        summary = fieldIDs.map { id in
            let value = values[id] ?? ""
            if let node = fieldComponents[id] { return (id, IOSIntelligentUIComponentValues.summary(value, for: node)) }
            if value.hasPrefix("[") { return (id, IOSIntelligentUIComponentValues.decodeSelection(value).sorted().joined(separator: "、")) }
            return (id, value == "true" ? "是" : value == "false" ? "否" : value)
        }
    }
}

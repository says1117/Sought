import SwiftUI

/// Eval screen: capture ground truth, load queries, run retrieval, share the raw run file.
struct EvalView: View {
    @ObservedObject var model: EvalViewModel
    @ObservedObject private var annotator: EvalGroundTruthAnnotator
    @State private var label = ""
    @State private var xText = ""
    @State private var zText = ""

    init(model: EvalViewModel) {
        self.model = model
        annotator = model.annotator
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Ground truth (Teach world frame, metres)") {
                    TextField("Object label", text: $label)
                    HStack {
                        TextField("x", text: $xText).keyboardType(.numbersAndPunctuation)
                        TextField("z", text: $zText).keyboardType(.numbersAndPunctuation)
                    }
                    Button("Add at x, z") {
                        if let x = Double(xText), let z = Double(zText) {
                            model.addObject(label: label, at: EvalFloorPoint(x: x, z: z))
                        }
                    }
                    .disabled(Double(xText) == nil || Double(zText) == nil)
                    if model.hasPoseSource {
                        Button("Add at phone position") { model.addObjectAtCurrentPose(label: label) }
                    }
                    ForEach(annotator.objects, id: \.id) { o in
                        Text(String(format: "%@  %@  (%.2f, %.2f)", o.id, o.label, o.x, o.z))
                    }
                    .onDelete { offsets in
                        for i in offsets { try? annotator.remove(id: annotator.objects[i].id) }
                    }
                    HStack {
                        Button("Save") { model.saveGroundTruth() }
                        Spacer()
                        Button("Load") { model.loadGroundTruth() }
                    }
                }
                Section("Queries") {
                    Text("\(model.queries.count) loaded from Documents/Eval/queries.yaml")
                    Button("Load queries") { model.loadQueries() }
                }
                Section("Run (offline retrieval)") {
                    Picker("Variant", selection: $model.variant) {
                        ForEach(EvalVariants.retrieval, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("App git commit", text: $model.commit).autocorrectionDisabled()
                    TextField("Phone height (for example mast_40cm)", text: $model.phoneHeight).autocorrectionDisabled()
                    Button("Run retrieval") { model.runRetrieval() }.disabled(!model.canRun)
                    if !model.canRun {
                        Text("Needs a track store, a text encoder, ground truth and queries.").font(.caption)
                    }
                    ForEach(model.outcomeCounts, id: \.0.rawValue) { Text("\($0.0.rawValue): \($0.1)") }
                    if let url = model.exportURL { ShareLink(item: url) { Label("Share run file", systemImage: "square.and.arrow.up") } }
                }
                if !model.status.isEmpty { Section { Text(model.status).font(.footnote) } }
            }
            .navigationTitle("Eval")
        }
    }
}

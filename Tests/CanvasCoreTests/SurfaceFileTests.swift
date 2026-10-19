import Foundation
import Testing
import CanvasCore

struct SurfaceFileTests {
    @Test func binaryAndEmptyFilesKeepTheirBytes() throws {
        for (encoded, count) in [("", 0), ("AA==", 1), ("AAE=", 2), ("AAEC", 3), ("AAECf4D/", 6)] {
            let file = try SurfaceFile(.object(["name": .string("proof.bin"), "type": .string("application/octet-stream"), "data": .string(encoded)]))
            #expect(file.byteCount == count)
        }
        let file = try SurfaceFile(name: "proof.bin", type: "application/octet-stream", bytes: Data([0, 1, 2, 127, 128, 255]))
        #expect(file.data == "AAECf4D/")
        #expect(file.byteCount == 6)
    }

    @Test func malformedFilePayloadsAreRejectedBeforePageMutation() {
        for encoded in ["A", "AA=", "A===", "AA==AAAA", "AA A", "????", "éééé"] {
            #expect(throws: ApiRouter.Failure.self) {
                try SurfaceFile(.object(["name": .string("bad.bin"), "type": .string(""), "data": .string(encoded)]))
            }
        }
        #expect(throws: ApiRouter.Failure.self) {
            try SurfaceFile(.object(["name": .string("bad.bin"), "type": .string(""), "data": .string(""), "path": .string("/not/a/viewer/permission")]))
        }
    }

    @Test func selectionCountAndAggregateBytesAreBounded() throws {
        #expect(throws: ApiRouter.Failure.self) { try SurfaceFile.parse(.array([])) }
        let first = try SurfaceFile(name: "first.bin", type: "", bytes: Data(repeating: 0, count: SurfaceFile.maxBytes / 2))
        let second = try SurfaceFile(name: "second.bin", type: "", bytes: Data(repeating: 1, count: SurfaceFile.maxBytes / 2))
        let accepted = try SurfaceFile.parse(.array([first.json, second.json]))
        #expect(accepted?.map(\.byteCount) == [4_194_304, 4_194_304])
        let extra = try SurfaceFile(name: "extra.bin", type: "", bytes: Data([2]))
        #expect(throws: ApiRouter.Failure.self) { try SurfaceFile.parse(.array([first.json, second.json, extra.json])) }
        let empty = try SurfaceFile(name: "empty.bin", type: "", bytes: Data())
        #expect(try SurfaceFile.parse(.array([empty.json]))?.map(\.byteCount) == [0])
        #expect(throws: ApiRouter.Failure.self) { try SurfaceFile.parse(.array(Array(repeating: empty.json, count: 33))) }
    }

    @Test func worstCaseEscapedBase64FitsTheSocketOutputBudget() throws {
        let file = try SurfaceFile(name: "full.bin", type: "application/octet-stream", bytes: Data(repeating: 255, count: SurfaceFile.maxBytes))
        let message = JSONValue.object([
            "id": .string("easld-1"), "method": .string("surface.answer"),
            "params": .object(["stream": .string("str_a"), "dialog": .string("dlg_a"), "accept": .bool(true), "files": .array([file.json])]),
        ])
        #expect(try JSONEncoder().encode(message).count < 32 << 20)
    }
}

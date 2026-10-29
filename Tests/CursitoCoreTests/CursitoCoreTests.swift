import Foundation
import Testing
@testable import CursitoCore

struct ExportInfoTests {
    private func infoOutput(machineID: String = "MAC-A", thisMachineID: String = "MAC-B", epoch: Int = 2_000, lastImport: Int = 0) -> String {
        """
        format=1
        host=Mac Studio
        machine_id=\(machineID)
        epoch=\(epoch)
        date=2026-10-29 10:58
        cursor=3.27.22
        this_machine_id=\(thisMachineID)
        last_import_epoch=\(lastImport)
        """
    }

    @Test func exportFromAnotherMacIsPendingUntilImported() throws {
        let neverImported = try #require(ExportInfo(porcelain: infoOutput()))
        #expect(neverImported.isPendingImport)
        #expect(neverImported.lastImportedExportAt == nil)

        let imported = try #require(ExportInfo(porcelain: infoOutput(lastImport: 2_000)))
        #expect(!imported.isPendingImport)
    }

    @Test func newerExportIsPendingAgain() throws {
        let info = try #require(ExportInfo(porcelain: infoOutput(epoch: 3_000, lastImport: 2_000)))
        #expect(info.isPendingImport)
    }

    @Test func exportFromThisMacIsNeverPending() throws {
        let info = try #require(ExportInfo(porcelain: infoOutput(machineID: "MAC-B")))
        #expect(info.isFromThisMac)
        #expect(!info.isPendingImport)
    }

    @Test func missingRequiredKeysYieldNil() {
        #expect(ExportInfo(porcelain: "host=Mac Studio\nepoch=2000") == nil)
    }
}

struct PorcelainTests {
    @Test func attachesDetailsToTheirItem() {
        let output = """
        ITEM\tchanged\t.agents/skills/\t2 difference(s)
        DETAIL\t.agents/skills/\tOnly in local: old-skill
        DETAIL\t.agents/skills/\tOnly in export: new-skill
        ITEM\tsame\t.cursor/mcp.json\tsame
        ITEM\tnew\textensions\t1 to install
        DETAIL\textensions\tfoo.bar
        """
        let items = Porcelain.items(in: output)

        #expect(items.map(\.name) == [".agents/skills/", ".cursor/mcp.json", "extensions"])
        #expect(items[0].state == .changed)
        #expect(items[0].details == ["Only in local: old-skill", "Only in export: new-skill"])
        #expect(items[1].details.isEmpty)
        #expect(items[2].details == ["foo.bar"])
    }

    @Test func keyValuesIgnoreItemLines() {
        let values = Porcelain.keyValues(in: "host=A=B\nITEM\tok\tx=y\tz\nbackup=/tmp/b")
        #expect(values == ["host": "A=B", "backup": "/tmp/b"])
    }

    @Test func reposKeepGitMessagesWithTheirRepo() {
        let output = """
        REPO\tPULLED\tapi\tmain +2 commit(s)
        REPO\tERROR\tweb\tfetch failed
        LOG\tweb\tfatal: could not read Username
        LOG\tweb\tremote: Repository not found
        REPO\tWEIRD\tdocs\t
        """
        let repos = Porcelain.repos(in: output)

        #expect(repos.map(\.name) == ["api", "web", "docs"])
        #expect(repos[0].state == .pulled && !repos[0].state.needsAttention)
        #expect(repos[1].state.needsAttention)
        #expect(repos[1].log == ["fatal: could not read Username", "remote: Repository not found"])
        #expect(repos[2].state == .error)
    }

    @Test func workLeftBehindCoversWhatOnlyLivesOnThisMac() {
        let output = """
        REPO\tOK\tapi\tmain up to date
        WIP\tapi\t3
        REPO\tAHEAD\tweb\tmain has 2 unpushed commit(s)
        REPO\tBEHIND\tdocs\tmain is 1 commit(s) behind (fetch only)
        REPO\tSKIP\tlab\tspike has no upstream branch
        WIP\tlab\t1
        """
        let repos = Porcelain.repos(in: output)

        #expect(repos.map(\.workLeftBehind) == [
            "3 uncommitted changes",
            "main has 2 unpushed commit(s)",
            nil,
            "1 uncommitted change · spike has no upstream branch",
        ])
    }

    @Test func errorMessagePrefersTheScriptErrorLine() {
        let output = "Export from Mac Studio\n\nerror: Cursor is open. Quit it.\n"
        #expect(Porcelain.errorMessage(in: output) == "Cursor is open. Quit it.")
        #expect(Porcelain.errorMessage(in: "something\nwent wrong\n") == "went wrong")
    }
}

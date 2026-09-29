import XCTest
@preconcurrency import Shared
@testable import iosApp

final class IOSSkillFileStoreTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() async throws {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
    }

    func testCreateSkillWritesSkillMdAndKmpScannerReadsIt() throws {
        let root = tempRoot()
        let store = IOSSkillFileStore(baseDirectory: root)

        let name = try store.createSkill(
            name: "Research Helper",
            description: "Use when the user asks for a concise research brief.",
            allowedTools: ["read", "rg", "web_search"]
        )

        XCTAssertEqual(name, "research-helper")
        let content = try store.readSkillMarkdown(dirName: name)
        XCTAssertTrue(content.contains(#"name: "research-helper""#))
        XCTAssertTrue(content.contains("allowed-tools: read rg web_search"))

        let validHiddenDirectory = store.skillsDirectory
            .appendingPathComponent(".research-helper-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: validHiddenDirectory, withIntermediateDirectories: true)
        try """
        ---
        name: ghost-staging
        description: Must not appear in the Skill scanner.
        ---
        """.write(
            to: validHiddenDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let invalidHiddenDirectory = store.skillsDirectory
            .appendingPathComponent(".invalid-staging", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidHiddenDirectory, withIntermediateDirectories: true)
        try "---\ndescription: missing name\n---\n".write(
            to: invalidHiddenDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let scanned = IosSkillFactory.shared.listSkills(documentsDir: root.path)
        XCTAssertEqual(scanned.count, 1)
        XCTAssertEqual(scanned.first?.name, "research-helper")
        XCTAssertEqual(scanned.first?.description_, "Use when the user asks for a concise research brief.")
        XCTAssertTrue(IosSkillFactory.shared.listIssues(documentsDir: root.path).isEmpty)
    }

    func testCreateSkillRejectsPathTraversalName() {
        let store = IOSSkillFileStore(baseDirectory: tempRoot())

        XCTAssertThrowsError(
            try store.createSkill(name: "../bad", description: "Use when testing.", allowedTools: [])
        )
    }

    func testSaveMarkdownRejectsNameChange() throws {
        let store = IOSSkillFileStore(baseDirectory: tempRoot())
        let name = try store.createSkill(name: "stable-skill", description: "Use when testing.", allowedTools: [])

        let changed = """
        ---
        name: "renamed-skill"
        description: "Use when testing."
        ---

        # renamed-skill
        """

        XCTAssertThrowsError(
            try store.saveSkillMarkdown(dirName: name, expectedName: name, content: changed)
        )
    }

    func testDeleteSkillRemovesLocalDirectory() throws {
        let store = IOSSkillFileStore(baseDirectory: tempRoot())
        let name = try store.createSkill(name: "delete-me", description: "Use when testing deletion.", allowedTools: [])

        try store.deleteSkill(dirName: name)

        XCTAssertThrowsError(try store.readSkillMarkdown(dirName: name))
    }

    func testRequiredBuiltinCanBeEditedButNotDeleted() throws {
        let store = IOSSkillFileStore(baseDirectory: tempRoot())
        let name = try XCTUnwrap(IOSBuiltinSkills.requiredNames.first)
        let markdown = try XCTUnwrap(IOSBuiltinSkills.markdown(for: name))
        try store.saveSkillFiles(files: ["SKILL.md": markdown], allowBuiltinSkill: true)

        let factoryDescriptionLine = try XCTUnwrap(
            markdown
                .split(separator: "\n", omittingEmptySubsequences: false)
                .first(where: { $0.hasPrefix("description:") })
                .map(String.init)
        )
        let edited = markdown.replacingOccurrences(
            of: factoryDescriptionLine,
            with: "description: 已迭代的触发说明。"
        )
        try store.saveSkillMarkdown(dirName: name, expectedName: name, content: edited)
        XCTAssertEqual(try store.readSkillMarkdown(dirName: name), edited)

        XCTAssertThrowsError(try store.deleteSkill(dirName: name)) { error in
            XCTAssertEqual(error as? IOSSkillFileStoreError, .builtinSkillProtected(name))
        }
        XCTAssertThrowsError(try store.createSkill(name: name, description: "dup", allowedTools: [])) { error in
            XCTAssertEqual(error as? IOSSkillFileStoreError, .builtinSkillProtected(name))
        }
    }

    func testRestoreFactoryContentKeepsSiblingFiles() throws {
        let store = IOSSkillFileStore(baseDirectory: tempRoot())
        let markdown = try XCTUnwrap(IOSBuiltinSkills.markdown(for: "skill-creator"))
        _ = try store.saveSkillFiles(
            files: [
                "SKILL.md": markdown,
                "references/notes.md": "# keep me\n",
            ],
            allowBuiltinSkill: true
        )

        try IOSBuiltinSkills.restoreFactoryContent(name: "skill-creator", into: store)

        let notes = try store.resolveSkillFile(name: "skill-creator", relativePath: "references/notes.md")
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "# keep me\n")
        XCTAssertTrue(try store.readSkillMarkdown(dirName: "skill-creator").contains("version: 2.2.0"))
    }

    func testSaveSkillFilesMergeExistingPreservesUnwrittenSiblings() throws {
        let store = IOSSkillFileStore(baseDirectory: tempRoot())
        _ = try store.saveSkillFiles(files: [
            "SKILL.md": """
            ---
            name: pack
            description: original
            ---

            # original
            """,
            "scripts/helper.js": "export const n = 1\n",
        ])

        _ = try store.saveSkillFiles(
            files: [
                "SKILL.md": """
                ---
                name: pack
                description: updated
                ---

                # updated
                """,
            ],
            mergeExisting: true
        )

        let helper = try store.resolveSkillFile(name: "pack", relativePath: "scripts/helper.js")
        XCTAssertEqual(try String(contentsOf: helper, encoding: .utf8), "export const n = 1\n")
        XCTAssertTrue(try store.readSkillMarkdown(dirName: "pack").contains("updated"))
    }

    func testSaveSkillFilesWithoutMergeReplacesPackage() throws {
        let store = IOSSkillFileStore(baseDirectory: tempRoot())
        _ = try store.saveSkillFiles(files: [
            "SKILL.md": """
            ---
            name: pack
            description: original
            ---

            # original
            """,
            "scripts/helper.js": "export const n = 1\n",
        ])

        _ = try store.saveSkillFiles(files: [
            "SKILL.md": """
            ---
            name: pack
            description: replaced
            ---

            # replaced
            """,
        ])

        let helper = try store.resolveSkillFile(name: "pack", relativePath: "scripts/helper.js")
        XCTAssertFalse(FileManager.default.fileExists(atPath: helper.path))
    }

    func testRollbackRejectsManifestReplacedByNewerImport() throws {
        let store = IOSSkillFileStore(baseDirectory: tempRoot())
        let name = "rollback-cas"
        let base = skillMarkdown(name: name, description: "base")
        let firstCandidate = skillMarkdown(name: name, description: "first candidate")
        let secondCandidate = skillMarkdown(name: name, description: "second candidate")
        _ = try store.saveSkillFiles(files: ["SKILL.md": base])

        let first = try store.prepareSkillPackage(
            importedFiles: ["SKILL.md": Data(firstCandidate.utf8)],
            mergeExisting: false
        )
        _ = try store.applySkillPackage(
            candidateFiles: first.candidate.files,
            name: name,
            expectedBaseHash: first.base?.hash,
            expectedCandidateHash: first.candidate.hash,
            enabledBefore: false,
            optionalSeedWasRemoved: false
        )
        guard case .available(let firstManifest) = try store.rollbackAvailability(name: name) else {
            return XCTFail("first import must publish a rollback manifest")
        }

        let second = try store.prepareSkillPackage(
            importedFiles: ["SKILL.md": Data(secondCandidate.utf8)],
            mergeExisting: false
        )
        _ = try store.applySkillPackage(
            candidateFiles: second.candidate.files,
            name: name,
            expectedBaseHash: second.base?.hash,
            expectedCandidateHash: second.candidate.hash,
            enabledBefore: true,
            optionalSeedWasRemoved: false
        )
        guard case .available(let secondManifest) = try store.rollbackAvailability(name: name) else {
            return XCTFail("second import must replace the rollback manifest")
        }

        XCTAssertThrowsError(
            try store.rollbackSkillPackage(name: name, expectedManifest: firstManifest)
        ) { error in
            XCTAssertEqual(
                error as? IOSSkillFileStoreError,
                .skillRollbackUnavailable("可回退版本已变化，请刷新后重试。")
            )
        }
        XCTAssertEqual(try store.readSkillMarkdown(dirName: name), secondCandidate)
        XCTAssertEqual(try store.rollbackAvailability(name: name), .available(secondManifest))

        _ = try store.rollbackSkillPackage(name: name, expectedManifest: secondManifest)
        XCTAssertEqual(try store.readSkillMarkdown(dirName: name), firstCandidate)
    }

    func testRegularNewImportRollbackRemovesPackageAndConsumesSlot() throws {
        let store = IOSSkillFileStore(baseDirectory: tempRoot())
        let name = "new-rollback"
        let markdown = skillMarkdown(name: name, description: "new package")
        let preparation = try store.prepareSkillPackage(
            importedFiles: ["SKILL.md": Data(markdown.utf8)],
            mergeExisting: false
        )
        XCTAssertEqual(preparation.kind, .new)

        _ = try store.applySkillPackage(
            candidateFiles: preparation.candidate.files,
            name: name,
            expectedBaseHash: nil,
            expectedCandidateHash: preparation.candidate.hash,
            enabledBefore: false,
            optionalSeedWasRemoved: false
        )
        guard case .available(let manifest) = try store.rollbackAvailability(name: name) else {
            return XCTFail("regular new import must publish an available rollback manifest")
        }
        XCTAssertEqual(manifest.kind, .new)
        let markdownURL = try store.resolveSkillFile(name: name, relativePath: "SKILL.md")

        _ = try store.rollbackSkillPackage(name: name, expectedManifest: manifest)

        XCTAssertFalse(FileManager.default.fileExists(atPath: markdownURL.path))
        XCTAssertEqual(
            try store.rollbackAvailability(name: name),
            .unavailable("没有可回退的上一次导入。")
        )
    }

    func testRequiredNewImportCannotRollbackToMissingState() throws {
        let store = IOSSkillFileStore(baseDirectory: tempRoot())
        let name = try XCTUnwrap(IOSBuiltinSkills.requiredNames.first)
        let markdown = try XCTUnwrap(IOSBuiltinSkills.markdown(for: name))
        let preparation = try store.prepareSkillPackage(
            importedFiles: ["SKILL.md": Data(markdown.utf8)],
            mergeExisting: false
        )
        XCTAssertEqual(preparation.kind, .new)

        _ = try store.applySkillPackage(
            candidateFiles: preparation.candidate.files,
            name: name,
            expectedBaseHash: nil,
            expectedCandidateHash: preparation.candidate.hash,
            enabledBefore: false,
            optionalSeedWasRemoved: false
        )
        let reason = "必需技能不能回退到缺失状态；如需重置，请使用恢复出厂。"
        XCTAssertEqual(try store.rollbackAvailability(name: name), .unavailable(reason))

        let manifestURL = store.skillsDirectory
            .appendingPathComponent(".previous", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            IOSSkillPreviousManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertThrowsError(
            try store.rollbackSkillPackage(name: name, expectedManifest: manifest)
        ) { error in
            XCTAssertEqual(
                error as? IOSSkillFileStoreError,
                .skillRollbackUnavailable(reason)
            )
        }
        XCTAssertEqual(try store.readSkillMarkdown(dirName: name), markdown)
    }

    private func skillMarkdown(name: String, description: String) -> String {
        """
        ---
        name: \(name)
        description: \(description)
        ---

        # \(description)
        """
    }

    // MARK: - P3a: request-preparation caching

    /// `readSkillMarkdown` caches by the SKILL.md file's modification time.
    /// A write made *outside* the store's own mutation paths (so the store's
    /// active invalidation never runs) must still be observed once the mtime
    /// changes — proving the stat-based invalidation itself, not just the
    /// store's own write-path invalidation.
    func testReadSkillMarkdownCacheInvalidatesWhenFileModifiedExternally() throws {
        let root = tempRoot()
        let store = IOSSkillFileStore(baseDirectory: root)
        let name = try store.createSkill(
            name: "Cache Probe",
            description: "Initial trigger text.",
            allowedTools: []
        )
        let first = try store.readSkillMarkdown(dirName: name)
        XCTAssertTrue(first.contains("Initial trigger text."))

        let skillMdURL = try store.skillDirectoryURL(name: name).appendingPathComponent("SKILL.md")
        let updated = """
        ---
        name: "\(name)"
        description: "Updated trigger text."
        ---

        # \(name)

        Updated trigger text.
        """
        try updated.write(to: skillMdURL, atomically: true, encoding: .utf8)
        // Force a distinct mtime regardless of filesystem timestamp resolution,
        // so the assertion doesn't depend on wall-clock timing.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: skillMdURL.path
        )

        let second = try store.readSkillMarkdown(dirName: name)
        XCTAssertTrue(second.contains("Updated trigger text."), "外部修改后应读到新内容，而不是命中过期缓存")
        XCTAssertFalse(second.contains("Initial trigger text."))
    }

    /// Same property for the directory listing cache: a skill directory added
    /// directly on disk (not through `createSkill`/`saveSkillFiles`, so the
    /// store's own invalidation calls never fire) must still show up once the
    /// parent directory's mtime moves.
    func testListSkillDirNamesCacheInvalidatesWhenDirectoryModifiedExternally() throws {
        let root = tempRoot()
        let store = IOSSkillFileStore(baseDirectory: root)
        _ = try store.createSkill(name: "existing-skill", description: "d", allowedTools: [])
        XCTAssertEqual(store.listSkillDirNames(), ["existing-skill"])

        let newSkillDir = store.skillsDirectory.appendingPathComponent("added-later", isDirectory: true)
        try FileManager.default.createDirectory(at: newSkillDir, withIntermediateDirectories: true)
        try "---\nname: added-later\ndescription: d\n---\n".write(
            to: newSkillDir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: store.skillsDirectory.path
        )

        XCTAssertEqual(store.listSkillDirNames().sorted(), ["added-later", "existing-skill"])
    }

    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-skill-file-store-\(UUID().uuidString)", isDirectory: true)
        tempDirs.append(url)
        return url
    }
}

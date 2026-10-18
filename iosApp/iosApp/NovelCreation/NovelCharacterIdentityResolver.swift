import Foundation

struct NovelCharacterIdentity: Equatable, Sendable {
    let materialID: NovelMaterialID
    let canonicalName: String
    let aliases: [String]
}

struct NovelCharacterIdentityResolver: Sendable {
    private let materialIDsByNormalizedName: [String: Set<NovelMaterialID>]

    init(identities: [NovelCharacterIdentity]) {
        var matches: [String: Set<NovelMaterialID>] = [:]
        for identity in identities {
            for name in [identity.canonicalName] + identity.aliases {
                let normalized = Self.normalize(name)
                guard !normalized.isEmpty else { continue }
                matches[normalized, default: []].insert(identity.materialID)
            }
        }
        materialIDsByNormalizedName = matches
    }

    func isKnown(_ name: String) -> Bool {
        materialIDsByNormalizedName[Self.normalize(name)]?.count == 1
    }

    static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func normalizedAliases(_ aliases: [String]) -> [String] {
        var seen: Set<String> = []
        return aliases.compactMap { alias in
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalize(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    /// Whether a free-text mention should ever surface as a **character identity**
    /// clarification card. Places, pure office/role titles (军需官), and generic
    /// crowd labels must not ask "对应哪位角色". Real personal names and
    /// surname+title forms (赵将军) stay eligible so they can alias to a dossier.
    static func isLikelyCharacterIdentityCandidate(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        if looksLikeChineseToponymOrInstitution(trimmed) { return false }
        if looksLikePolityOrRegime(trimmed) { return false }
        if looksLikeLatinToponymOrInstitution(trimmed) { return false }
        if looksLikePureOfficeOrRoleTitle(trimmed) { return false }
        if looksLikeGenericCrowdLabel(trimmed) { return false }
        return true
    }

    /// High-confidence Chinese place / institution endings (澶州、汴京、开封府).
    /// Keep the set tight: do not include 山/河/江 alone — they appear in person names.
    private static let namedNaturalFeatures: Set<String> = [
        "黄河",
    ]

    private static let chinesePlaceOrInstitutionSuffixes: [String] = [
        "特别行政区", "自治区", "自治州", "自治县",
        "省", "市", "州", "府", "县", "郡", "镇", "乡", "村", "庄", "堡", "寨",
        "国", "邦", "京", "都",
        "路", "街", "巷", "道",
        "渡口", "关", "津", "渡", "湾", "港", "岛", "洲",
        "寺", "庙", "宫", "殿", "观", "庵",
        "衙", "署", "监", "营", "卫",
    ]

    private static func looksLikeChineseToponymOrInstitution(_ name: String) -> Bool {
        if namedNaturalFeatures.contains(name) { return true }
        for suffix in chinesePlaceOrInstitutionSuffixes where name.hasSuffix(suffix) {
            // Suffix alone is not a mention; require a stem (澶+州, 汴+京).
            if name.count > suffix.count { return true }
        }
        return false
    }

    /// Dynasties, regimes, and ethnic polities used as places (契丹、北汉).
    /// Suffix rules miss these because they have no 州/京/府 ending.
    private static let namedPolitiesAndRegimes: Set<String> = [
        "契丹", "女真", "蒙古", "回鹘", "吐蕃", "党项", "渤海",
        "高丽", "新罗", "百济", "安南", "交趾",
        "西夏", "大理", "大辽", "大金", "大蒙古",
        "吴越", "荆南", "北齐", "东魏", "西魏",
    ]

    private static let dynastyDirectionPrefixes: Set<Character> = [
        "南", "北", "东", "西", "后", "前", "大",
    ]

    private static let dynastyStems: Set<Character> = [
        "汉", "唐", "宋", "齐", "周", "魏", "晋", "梁", "楚", "吴", "越", "辽", "金", "元", "明", "清",
    ]

    private static func looksLikePolityOrRegime(_ name: String) -> Bool {
        if namedPolitiesAndRegimes.contains(name) { return true }
        if name.count == 2,
           let prefix = name.first,
           let stem = name.last,
           dynastyDirectionPrefixes.contains(prefix),
           dynastyStems.contains(stem) {
            return true
        }
        if name.count == 2, name.hasSuffix("朝"),
           let stem = name.first, dynastyStems.contains(stem) {
            return true
        }
        return false
    }

    private static let latinPlaceOrInstitutionSuffixes: [String] = [
        " city", " county", " province", " kingdom", " empire", " republic",
        " street", " road", " avenue", " mountain", " river", " lake", " sea",
        " island", " bay", " harbor", " harbour", " castle", " fort", " temple",
        " palace", " abbey", " cathedral", " monastery",
    ]

    private static func looksLikeLatinToponymOrInstitution(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return latinPlaceOrInstitutionSuffixes.contains { lowered.hasSuffix($0) }
    }

    /// Exact one-off office / role strings that are not personal identities.
    private static let pureRoleTitles: Set<String> = [
        "军需官", "粮草官", "转运使", "县令", "知县", "知府", "知州", "通判", "主簿", "县尉",
        "推官", "参军", "将军", "元帅", "都督", "节度使", "都头", "押司", "虞候", "教头",
        "都监", "提辖", "团练", "百户", "千户", "万户", "指挥使", "都指挥使",
        "侍卫", "侍女", "丫鬟", "太监", "公公", "掌柜", "店小二", "小二",
        "脚夫", "车夫", "船夫", "水手", "探子", "细作", "小厮", "家丁", "护院",
        "门子", "更夫", "厨子", "账房", "捕快", "差役", "衙役", "士卒", "兵士",
        "亲兵", "护卫", "驿卒", "信使", "使者", "商贾", "贩子", "路人", "行人",
        "客人", "来人", "某人", "那人", "此人", "对方", "众人", "群臣", "百官",
        "士兵", "兵丁", "校尉", "都尉", "司马", "太尉", "丞相", "宰相", "尚书",
        "侍郎", "给事中", "中书令", "枢密使", "宣徽使", "内侍", "内官",
    ]

    /// Longer suffixes first so 军需官 wins over bare 官.
    private static let roleTitleSuffixes: [String] = [
        "都指挥使", "节度使", "指挥使", "军需官", "粮草官", "转运使",
        "知州", "知府", "知县", "通判", "主簿", "县尉", "推官", "参军",
        "将军", "元帅", "都督", "都头", "押司", "虞候", "教头", "都监", "提辖", "团练",
        "侍卫", "侍女", "丫鬟", "太监", "掌柜", "小二", "脚夫", "车夫", "船夫",
        "探子", "细作", "小厮", "家丁", "护院", "门子", "更夫", "厨子", "账房",
        "捕快", "差役", "衙役", "士卒", "兵士", "亲兵", "护卫", "驿卒", "信使",
        "校尉", "都尉", "司马", "太尉", "丞相", "宰相", "尚书", "侍郎",
        "大人", "老爷", "夫人", "小姐", "公子", "殿下", "陛下", "官家",
        "师父", "师傅", "道人", "和尚", "尼姑", "先生",
        "县令", "使者",
        // Short occupational endings: only with non-person stems (see below).
        "官", "令", "丞", "尉", "吏", "使", "卒", "兵",
    ]

    private static let commonChineseSurnames: Set<Character> = Set(
        "赵钱孙李周吴郑王冯陈褚卫蒋沈韩杨朱秦尤许何吕施张孔曹严华金魏陶姜戚谢邹喻柏水窦章云苏潘葛奚范彭郎鲁韦昌马苗凤花方俞任袁柳酆鲍史唐费廉岑薛雷贺倪汤滕殷罗毕郝邬安常乐于时傅皮卞齐康伍余元卜顾孟平黄和穆萧尹姚邵湛汪祁毛禹狄米贝明臧计伏成戴谈宋茅庞熊纪舒屈项祝董梁杜阮蓝闵席季麻强贾路娄危江童颜郭梅盛林刁钟徐邱骆高夏蔡田樊胡凌霍虞万支柯昝管卢莫经房裘缪干解应宗丁宣贲邓郁单杭洪包诸左石崔吉钮龚程嵇邢滑裴陆荣翁荀羊於惠甄曲家封芮羿储靳汲邴糜松井段富巫乌焦巴弓牧隗山谷车侯宓蓬全郗班仰秋仲伊宫宁仇栾暴甘钭厉戎祖武符刘景詹束龙叶幸司韶郜黎蓟薄印宿白怀蒲邰从鄂索咸籍赖卓蔺屠蒙池乔阴郁胥能苍双闻莘党翟谭贡劳逄姬申扶堵冉宰郦雍却璩桑桂濮牛寿通边扈燕冀郏浦尚农温别庄晏柴瞿阎充慕连茹习宦艾鱼容向古易慎戈廖庾终暨居衡步都耿满弘匡国文寇广禄阙东欧殳沃利蔚越夔隆师巩厍聂晁勾敖融冷訾辛阚那简饶空曾毋沙乜养鞠须丰巢关蒯相查后荆红游竺权逯盖益桓公"
            .map { $0 }
    )

    private static let nonPersonRoleStems: Set<String> = [
        "殿前", "城门", "城中", "城外", "军中", "营中", "营前", "帐前", "帐下",
        "府中", "衙门", "衙内", "路上", "路边", "店中", "店里", "村中", "乡里",
        "禁中", "宫中", "宫里", "朝中", "朝堂", "堂上", "门外", "门内",
        "左右", "两侧", "周围", "附近", "当地", "本城", "本州", "本府", "本县",
        "敌军", "官军", "宋军", "汉军", "辽军", "唐军", "明军",
    ]

    private static func looksLikePureOfficeOrRoleTitle(_ name: String) -> Bool {
        if pureRoleTitles.contains(name) { return true }
        for suffix in roleTitleSuffixes {
            guard name.hasSuffix(suffix), name.count >= suffix.count else { continue }
            let stem = String(name.dropLast(suffix.count))
            if stem.isEmpty {
                // Bare title: 将军 / 军需官
                return true
            }
            if nonPersonRoleStems.contains(stem) {
                // 殿前军需官 / 城门守卒-style compounds without a person name.
                return true
            }
            // 赵将军 / 李知县 → personal reference; keep for alias matching.
            if stem.count == 1, let ch = stem.first, commonChineseSurnames.contains(ch) {
                return false
            }
            // Multi-character stem that looks like a real name → keep.
            if stem.count >= 2, looksLikePersonalNameStem(stem) {
                return false
            }
            // Title-ish compound with non-name stem (e.g. 北门守卒 if 守卒 in suffixes).
            if suffix.count >= 2 { return true }
        }
        return false
    }

    private static func looksLikePersonalNameStem(_ stem: String) -> Bool {
        guard let first = stem.first else { return false }
        // Common pattern: surname + 1–2 given-name chars.
        if commonChineseSurnames.contains(first), (2...3).contains(stem.count) {
            return true
        }
        // Latin personal token.
        if stem.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || $0 == "-" || $0 == "'" }),
           stem.count >= 2 {
            return true
        }
        return false
    }

    private static let genericCrowdLabels: Set<String> = [
        "路人", "行人", "众人", "群臣", "百官", "士兵", "兵丁", "来人", "客人",
        "某人", "那人", "此人", "对方", "百姓", "乡民", "村民", "市民", "官员",
        "将士", "将领", "部将", "手下", "随从", "侍从", "宾客", "僚属",
    ]

    private static func looksLikeGenericCrowdLabel(_ name: String) -> Bool {
        genericCrowdLabels.contains(name) || name.hasSuffix("敌军")
    }

    /// Deterministic best existing-character match for a free mention.
    /// Used as the identity-card one-tap default (no network). `nil` when no
    /// candidate clears the confidence floor — then the UI only offers create/ignore.
    static func recommendedIdentityMatch(
        mention: String,
        candidates: [(id: String, title: String, aliases: [String])]
    ) -> (id: String, title: String, score: Int)? {
        let mentionKey = normalize(mention)
        guard !mentionKey.isEmpty, isLikelyCharacterIdentityCandidate(mention) else { return nil }
        var best: (id: String, title: String, score: Int)?
        for candidate in candidates {
            let names = ([candidate.title] + candidate.aliases)
                .map { normalize($0) }
                .filter { !$0.isEmpty }
            guard !names.isEmpty else { continue }
            let score = names.map { identityMatchScore(mention: mentionKey, candidate: $0) }.max() ?? 0
            guard score >= identityRecommendationMinimumScore else { continue }
            if let current = best {
                if score > current.score ||
                    (score == current.score &&
                        candidate.title.localizedStandardCompare(current.title) == .orderedAscending) {
                    best = (candidate.id, candidate.title, score)
                }
            } else {
                best = (candidate.id, candidate.title, score)
            }
        }
        return best
    }

    /// Floor for showing a one-tap default. Below this, force explicit choice / create.
    static let identityRecommendationMinimumScore = 40

    static func identityMatchScore(mention: String, candidate: String) -> Int {
        if mention == candidate { return 1_000 }
        if mention.count >= 2, candidate.hasSuffix(mention) { return 520 }
        if candidate.count >= 2, mention.hasSuffix(candidate) { return 500 }
        if mention.count >= 2, candidate.contains(mention) { return 360 }
        if candidate.count >= 2, mention.contains(candidate) { return 340 }
        // Shared leading surname / token for CJK or Latin names.
        // Bare same-surname alone must stay BELOW the one-tap floor so
        // “赵云” does not force-confirm as “赵匡胤”.
        if mention.count >= 2, candidate.count >= 2,
           mention.prefix(1) == candidate.prefix(1) {
            let sharedTail = sharedSuffixLength(mention, candidate)
            if sharedTail >= 2 { return 220 + sharedTail * 10 }
            return 30
        }
        let shared = sharedCharacterCount(mention, candidate)
        if shared >= 2 {
            let ratio = Double(shared) / Double(max(mention.count, candidate.count))
            return Int(60.0 + ratio * 80.0)
        }
        return 0
    }

    private static func sharedSuffixLength(_ a: String, _ b: String) -> Int {
        var count = 0
        var ai = a.endIndex
        var bi = b.endIndex
        while ai > a.startIndex, bi > b.startIndex {
            ai = a.index(before: ai)
            bi = b.index(before: bi)
            guard a[ai] == b[bi] else { break }
            count += 1
        }
        return count
    }

    private static func sharedCharacterCount(_ a: String, _ b: String) -> Int {
        var bag: [Character: Int] = [:]
        for ch in a { bag[ch, default: 0] += 1 }
        var shared = 0
        for ch in b {
            guard let n = bag[ch], n > 0 else { continue }
            bag[ch] = n - 1
            shared += 1
        }
        return shared
    }
}

/// Derived-state setting proposals: keep recurring story-defining cards,
/// drop one-scene furniture (粮仓、谁家后院).
enum NovelSettingProposalFilter: Sendable {
    static func isWorthProposing(title: String, content: String = "") -> Bool {
        _ = content
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        return !isSceneDressingTitle(trimmed)
    }

    static func shouldSurface(_ proposal: NovelSettingProposalRecord) -> Bool {
        switch proposal.origin {
        case .some(.quickStart), .some(.contextualCharacter):
            return true
        case .some(.derivedState), nil:
            return isWorthProposing(title: proposal.title, content: proposal.content)
        }
    }

    private static let sceneDressingTitles: Set<String> = [
        "粮仓", "马厩", "马棚", "牛棚", "猪圈", "鸡窝",
        "厢房", "耳房", "偏房", "后院", "前院", "前厅", "正厅", "堂屋",
        "灶房", "厨房", "柴房", "茅厕", "茅房", "井台", "水井",
        "库房", "地窖", "阁楼", "客房", "酒窖", "柴堆",
        "院子", "宅院", "门房", "门楼", "庭院", "谁家",
    ]

    private static let sceneDressingSuffixes: [String] = [
        "粮仓", "马厩", "马棚", "后院", "前院", "厢房", "灶房", "厨房",
        "柴房", "茅厕", "院子", "宅院", "庭院", "门房",
    ]

    private static func isSceneDressingTitle(_ title: String) -> Bool {
        if sceneDressingTitles.contains(title) { return true }
        if title.count == 2, title.hasSuffix("家") { return true }
        for suffix in sceneDressingSuffixes where title.hasSuffix(suffix) && title.count > suffix.count {
            let stem = String(title.dropLast(suffix.count)).replacingOccurrences(of: "的", with: "")
            if stem.hasSuffix("家") || stem.count <= 2 { return true }
        }
        return false
    }
}

import SwiftUI

struct ContentView: View {
    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = false
    @StateObject private var store = ClubStore()

    @State private var selectedTab: ClubTab = .club
    @State private var selectedGame: SkillGame?
    @State private var selectedRelic: Relic?
    @State private var onboardingPage = 0

    var body: some View {
        ZStack {
            ClubBackground().ignoresSafeArea()

            if didCompleteOnboarding {
                mainExperience
            } else {
                onboardingExperience
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            store.refreshDayBoundaries()
        }
    }

    private var mainExperience: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                tabBody
                    .padding(.bottom, 102)

                ClubTabBar(selectedTab: $selectedTab)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            .fullScreenCover(item: $selectedGame) { game in
                GameDetailView(game: game, store: store)
            }
            .sheet(item: $selectedRelic) { relic in
                RelicDetailView(relic: relic, unlocked: store.unlockedRelicIDs.contains(relic.id))
                    .presentationDetents([.fraction(0.55)])
            }
        }
    }

    private var onboardingExperience: some View {
        let pages = OnboardingPage.samplePages
        return VStack(spacing: 18) {
            Spacer(minLength: 28)
            HStack {
                Text("Royal Fortune Club")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(ClubPalette.accent)
                Spacer()
                Text("\(onboardingPage + 1)/\(pages.count)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ClubPalette.mutedText)
            }
            .padding(.horizontal, 24)

            TabView(selection: $onboardingPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    OnboardingPageView(page: page)
                        .tag(index)
                        .padding(.horizontal, 16)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 8) {
                ForEach(0..<pages.count, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(index == onboardingPage ? ClubPalette.accent : ClubPalette.cardBorder)
                        .frame(width: index == onboardingPage ? 24 : 8, height: 8)
                        .animation(.easeInOut(duration: 0.2), value: onboardingPage)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 10)

            Button {
                if onboardingPage < pages.count - 1 {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) {
                        onboardingPage += 1
                    }
                } else {
                    withAnimation(.easeInOut) {
                        didCompleteOnboarding = true
                    }
                }
            } label: {
                Text(onboardingPage < pages.count - 1 ? "Next" : "Enter Club")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(ClubPalette.background)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        LinearGradient(
                            colors: [ClubPalette.accent, ClubPalette.accentStrong],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    @ViewBuilder
    private var tabBody: some View {
        switch selectedTab {
        case .club:
            ClubScreen(store: store, onOpenGames: { selectedTab = .games })
        case .games:
            GamesScreen(store: store, onOpenGame: { selectedGame = $0 })
        case .collection:
            CollectionScreen(store: store, onOpenRelic: { selectedRelic = $0 })
        case .tasks:
            TasksScreen(store: store, onOpenGames: { selectedTab = .games })
        case .profile:
            ProfileScreen(store: store, onOpenGames: { selectedTab = .games })
        }
    }
}

final class ClubStore: ObservableObject {
    @Published private(set) var state: ClubState

    private let storageKey = "club_state_v2"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(ClubState.self, from: data) {
            state = decoded
        } else {
            state = ClubState.defaultState
        }
        refreshDayBoundaries()
        unlockRelicsIfNeeded()
    }

    var balancePoints: Int { state.balancePoints }
    var prestigePoints: Int { state.prestigePoints }
    var dailyProgress: Int { state.dailyProgress }
    var weeklyProgress: Int { state.weeklyProgress }
    var streak: Int { state.streak }
    var relicsFound: Int { state.unlockedRelicIDs.count }
    var gamesPlayed: Int { state.gamesPlayed }
    var currentBoost: BoostType? { state.currentBoost }
    var unlockedRelicIDs: Set<String> { Set(state.unlockedRelicIDs) }

    var canClaimDaily: Bool {
        state.lastDailyClaimDate != Self.todayKey()
    }

    var activeRank: RankInfo {
        RankInfo.current(for: state.prestigePoints)
    }

    var nextRankProgress: Double {
        activeRank.progress(for: state.prestigePoints)
    }

    var bestGameTitle: String {
        guard let pair = state.bestScores.max(by: { $0.value < $1.value }),
              let game = SkillGame(rawValue: pair.key) else { return "-" }
        return game.title
    }

    var favoriteSession: String {
        state.weeklyProgress >= 10 ? "Momentum Session" : "Spotlight Session"
    }

    var todayCircuitCount: Int {
        state.circuitCompletedIDs.count
    }

    var hasCompletedDailyTask: Bool {
        state.dailyProgress >= 3
    }

    var dailyTaskCompletions: Int {
        state.dailyTaskCompletions
    }

    func refreshDayBoundaries() {
        let today = Self.todayKey()
        if state.lastDailyResetDate != today {
            state.lastDailyResetDate = today
            state.dailyProgress = 0
            state.circuitCompletedIDs = []
            state.currentBoost = nil
        }

        let week = Self.weekKey()
        if state.weekKey != week {
            state.weekKey = week
            state.weeklyProgress = 0
        }

        save()
    }

    func claimDailyStreakReward() {
        refreshDayBoundaries()
        guard canClaimDaily else { return }

        let yesterday = Self.yesterdayKey()
        if state.lastDailyClaimDate == yesterday {
            state.streak = min(7, state.streak + 1)
        } else {
            state.streak = 1
        }

        let rewards = [500, 800, 1100, 1500, 2000, 2700, 3500]
        let reward = rewards[max(0, min(state.streak - 1, rewards.count - 1))]
        state.balancePoints += reward
        state.lastDailyClaimDate = Self.todayKey()
        state.lastActiveDate = Self.todayKey()

        unlockRelicsIfNeeded()
        save()
    }

    func claimBoost() {
        guard state.currentBoost == nil else { return }
        state.currentBoost = BoostType.allCases.randomElement() ?? .precision
        save()
    }

    func completeGame(game: SkillGame, score: Int, success: Bool) {
        state.gamesPlayed += 1
        state.lastActiveDate = Self.todayKey()

        let key = game.rawValue
        let existing = state.bestScores[key] ?? 0
        state.bestScores[key] = max(existing, score)

        guard success else {
            save()
            return
        }

        var finalReward = game.reward
        if let boost = state.currentBoost {
            switch boost {
            case .precision:
                if score >= 90 {
                    finalReward += 220
                }
            case .focus:
                finalReward += 150
            case .reward:
                finalReward += max(100, Int(Double(game.reward) * 0.25))
            }
            state.currentBoost = nil
        }

        state.balancePoints += finalReward
        state.prestigePoints += 25
        state.dailyProgress = min(3, state.dailyProgress + 1)
        state.weeklyProgress += 1
        state.circuitCompletedIDs.insert(game.rawValue)

        if state.dailyProgress == 3 && !state.dailyCompletionMarkDates.contains(Self.todayKey()) {
            state.dailyCompletionMarkDates.insert(Self.todayKey())
            state.dailyTaskCompletions += 1
        }

        unlockRelicsIfNeeded()
        save()
    }

    func isRelicUnlocked(_ relic: Relic) -> Bool {
        unlockedRelicIDs.contains(relic.id)
    }

    private func unlockRelicsIfNeeded() {
        if state.gamesPlayed >= 3 {
            state.unlockedRelicIDs.insert(Relic.goldenCrest.id)
        }
        if (state.bestScores[SkillGame.pulseTap.rawValue] ?? 0) >= 75 {
            state.unlockedRelicIDs.insert(Relic.crystalEmblem.id)
        }
        if state.streak >= 3 {
            state.unlockedRelicIDs.insert(Relic.rubyDice.id)
        }
        if state.balancePoints >= 20_000 {
            state.unlockedRelicIDs.insert(Relic.emeraldToken.id)
        }
        if state.gamesPlayed >= 10 {
            state.unlockedRelicIDs.insert(Relic.royalKey.id)
        }
        if state.dailyTaskCompletions >= 5 {
            state.unlockedRelicIDs.insert(Relic.midnightSeal.id)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        objectWillChange.send()
    }

    private static func todayKey() -> String {
        let f = DateFormatter()
        f.calendar = .current
        f.locale = .current
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static func yesterdayKey() -> String {
        let date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let f = DateFormatter()
        f.calendar = .current
        f.locale = .current
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func weekKey() -> String {
        let cal = Calendar(identifier: .iso8601)
        let comp = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return "\(comp.yearForWeekOfYear ?? 0)-W\(comp.weekOfYear ?? 0)"
    }
}

struct ClubState: Codable {
    var balancePoints: Int
    var prestigePoints: Int
    var gamesPlayed: Int
    var dailyProgress: Int
    var weeklyProgress: Int
    var streak: Int
    var lastDailyClaimDate: String
    var lastDailyResetDate: String
    var lastActiveDate: String
    var weekKey: String
    var currentBoost: BoostType?
    var bestScores: [String: Int]
    var circuitCompletedIDs: Set<String>
    var unlockedRelicIDs: Set<String>
    var dailyCompletionMarkDates: Set<String>
    var dailyTaskCompletions: Int

    static let defaultState = ClubState(
        balancePoints: 12_800,
        prestigePoints: 0,
        gamesPlayed: 0,
        dailyProgress: 0,
        weeklyProgress: 2,
        streak: 1,
        lastDailyClaimDate: "",
        lastDailyResetDate: "",
        lastActiveDate: "",
        weekKey: "",
        currentBoost: nil,
        bestScores: [:],
        circuitCompletedIDs: [],
        unlockedRelicIDs: [],
        dailyCompletionMarkDates: [],
        dailyTaskCompletions: 0
    )
}

enum ClubTab: String, CaseIterable, Identifiable {
    case club
    case games
    case collection
    case tasks
    case profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .club: return "Club"
        case .games: return "Games"
        case .collection: return "Collection"
        case .tasks: return "Tasks"
        case .profile: return "Profile"
        }
    }

    var icon: String {
        switch self {
        case .club: return "house.fill"
        case .games: return "gamecontroller.fill"
        case .collection: return "square.grid.2x2.fill"
        case .tasks: return "checklist"
        case .profile: return "person.crop.circle.fill"
        }
    }
}

enum BoostType: String, Codable, CaseIterable {
    case precision
    case focus
    case reward

    var title: String {
        switch self {
        case .precision: return "Precision Boost"
        case .focus: return "Focus Boost"
        case .reward: return "Reward Boost"
        }
    }
}

enum SkillGame: String, CaseIterable, Identifiable, Codable {
    case pulseTap
    case patternMatch
    case focusOrbit
    case pathRelay
    case sequenceEcho
    case signalHunt
    case mirrorRelay
    case logicFilter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pulseTap: return "Pulse Tap"
        case .patternMatch: return "Pattern Match"
        case .focusOrbit: return "Focus Orbit"
        case .pathRelay: return "Path Relay"
        case .sequenceEcho: return "Sequence Echo"
        case .signalHunt: return "Signal Hunt"
        case .mirrorRelay: return "Mirror Relay"
        case .logicFilter: return "Logic Filter"
        }
    }

    var subtitle: String {
        switch self {
        case .pulseTap: return "Tap when the marker is inside the focus zone."
        case .patternMatch: return "Reveal matching pairs with minimal mistakes."
        case .focusOrbit: return "Stop orbiting pulse inside the highlighted arc."
        case .pathRelay: return "Repeat the direction path without breaking order."
        case .sequenceEcho: return "Memorize and replay the flashing sequence."
        case .signalHunt: return "React only to true signals, ignore false alerts."
        case .mirrorRelay: return "Repeat commands in mirrored direction."
        case .logicFilter: return "Catch numbers that match the active rule."
        }
    }

    var tags: [String] {
        switch self {
        case .pulseTap: return ["Timing", "Reflex"]
        case .patternMatch: return ["Memory", "Speed"]
        case .focusOrbit: return ["Focus", "Precision"]
        case .pathRelay: return ["Control", "Flow"]
        case .sequenceEcho: return ["Memory", "Rhythm"]
        case .signalHunt: return ["Reaction", "Focus"]
        case .mirrorRelay: return ["Logic", "Control"]
        case .logicFilter: return ["Reasoning", "Speed"]
        }
    }

    var reward: Int {
        switch self {
        case .pulseTap: return 400
        case .patternMatch: return 520
        case .focusOrbit: return 600
        case .pathRelay: return 480
        case .sequenceEcho: return 700
        case .signalHunt: return 550
        case .mirrorRelay: return 620
        case .logicFilter: return 650
        }
    }

    var icon: String {
        switch self {
        case .pulseTap: return "scope"
        case .patternMatch: return "square.grid.2x2"
        case .focusOrbit: return "target"
        case .pathRelay: return "point.3.connected.trianglepath.dotted"
        case .sequenceEcho: return "waveform.path.ecg"
        case .signalHunt: return "dot.radiowaves.left.and.right"
        case .mirrorRelay: return "arrow.left.and.right.square"
        case .logicFilter: return "number.square"
        }
    }

    var difficulty: String {
        switch self {
        case .pulseTap, .patternMatch, .pathRelay, .signalHunt, .mirrorRelay: return "Medium"
        case .focusOrbit, .sequenceEcho, .logicFilter: return "Hard"
        }
    }

    var rules: [String] {
        switch self {
        case .pulseTap:
            return [
                "Watch the moving marker.",
                "Tap while it stays in the highlighted window.",
                "Complete 3 rounds with high timing accuracy."
            ]
        case .patternMatch:
            return [
                "Open two cards at a time.",
                "Match all pairs within the move budget.",
                "Fewer mistakes increase your score."
            ]
        case .focusOrbit:
            return [
                "A pulse rotates around the circle.",
                "Tap when it enters the active arc.",
                "Hold consistency across 3 rounds."
            ]
        case .pathRelay:
            return [
                "Memorize the direction sequence.",
                "Repeat it exactly using controls.",
                "Complete all sets without chain breaks."
            ]
        case .sequenceEcho:
            return [
                "Watch highlighted pads in order.",
                "Repeat the same order from memory.",
                "Longer successful chains mean higher score."
            ]
        case .signalHunt:
            return [
                "Signals appear one by one.",
                "Tap only the true signal type.",
                "Avoid false taps to keep accuracy high."
            ]
        case .mirrorRelay:
            return [
                "Read each direction command.",
                "Input the mirrored direction instead.",
                "Keep errors low to finish with high accuracy."
            ]
        case .logicFilter:
            return [
                "A rule is shown at the top.",
                "Catch only numbers that match the rule.",
                "Wrong catches reduce your final score."
            ]
        }
    }
}

struct Relic: Identifiable {
    let id: String
    let title: String
    let requirement: String
    let symbol: String

    static let goldenCrest = Relic(id: "golden_crest", title: "Golden Crest", requirement: "Complete 3 games", symbol: "crown.fill")
    static let crystalEmblem = Relic(id: "crystal_emblem", title: "Crystal Emblem", requirement: "Reach 75+ in Pulse Tap", symbol: "seal.fill")
    static let rubyDice = Relic(id: "ruby_dice", title: "Ruby Dice", requirement: "Reach 3-day streak", symbol: "die.face.5.fill")
    static let emeraldToken = Relic(id: "emerald_token", title: "Emerald Token", requirement: "Earn 20 000 points", symbol: "hexagon.fill")
    static let royalKey = Relic(id: "royal_key", title: "Royal Key", requirement: "Complete 10 games", symbol: "key.fill")
    static let midnightSeal = Relic(id: "midnight_seal", title: "Midnight Seal", requirement: "Finish 5 daily tasks", symbol: "seal.fill")

    static let all: [Relic] = [
        .goldenCrest,
        .crystalEmblem,
        .rubyDice,
        .emeraldToken,
        .royalKey,
        .midnightSeal
    ]
}

struct RankInfo {
    let title: String
    let start: Int
    let end: Int

    static let ranks: [RankInfo] = [
        .init(title: "Guest Royal", start: 0, end: 200),
        .init(title: "Bronze Royal", start: 200, end: 600),
        .init(title: "Silver Royal", start: 600, end: 1200),
        .init(title: "Golden Royal", start: 1200, end: 2000),
        .init(title: "Crown Member", start: 2000, end: 3000)
    ]

    static func current(for points: Int) -> RankInfo {
        ranks.last(where: { points >= $0.start }) ?? ranks[0]
    }

    func progress(for points: Int) -> Double {
        guard end > start else { return 1 }
        let clamped = min(max(points, start), end)
        return Double(clamped - start) / Double(end - start)
    }

    var nextTitle: String {
        if let next = RankInfo.ranks.first(where: { $0.start == end }) {
            return next.title
        }
        return "Max Rank"
    }
}

struct FeedNote: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

struct OnboardingPage {
    let title: String
    let subtitle: String
    let text: String
    let bullets: [String]
    let icon: String

    static let samplePages: [OnboardingPage] = [
        .init(
            title: "Welcome to Royal Fortune Club",
            subtitle: "Enter a private skill arcade.",
            text: "Play skill games, earn Club Points, and unlock rare royal rewards.",
            bullets: ["Skill-based challenges", "No cash mechanics", "Private club progression"],
            icon: "crown.fill"
        ),
        .init(
            title: "Play Skill Games",
            subtitle: "Every game tests timing, focus, or memory.",
            text: "Complete private challenges and improve your best results each session.",
            bullets: ["Mirror Relay", "Logic Filter", "Focus Orbit"],
            icon: "gamecontroller.fill"
        ),
        .init(
            title: "Unlock the Collection",
            subtitle: "Collect rare Royal Relics.",
            text: "Finish tasks and complete games to reveal exclusive club items.",
            bullets: ["Golden Crest", "Ruby Dice", "Royal Key"],
            icon: "lock.shield.fill"
        ),
        .init(
            title: "Build Your Royal Status",
            subtitle: "Return daily and rise through the club.",
            text: "Keep your streak alive, complete tasks, and climb from Guest Royal to Crown Member.",
            bullets: [],
            icon: "medal.fill"
        )
    ]
}

enum ClubPalette {
    static let background = Color(hex: "#0A1016")
    static let surface = Color(hex: "#111B25")
    static let card = Color(hex: "#182635")
    static let cardBorder = Color(hex: "#2A3D52")
    static let accent = Color(hex: "#5DD6C0")
    static let accentStrong = Color(hex: "#2EA7A2")
    static let emerald = Color(hex: "#68E2A9")
    static let mutedText = Color(hex: "#98AABD")
    static let white = Color(hex: "#F4F8FF")
    static let blueAccent = Color(hex: "#64AFFF")
}

struct ClubBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [ClubPalette.background, ClubPalette.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(ClubPalette.blueAccent.opacity(0.17))
                .frame(width: 290, height: 290)
                .blur(radius: 72)
                .offset(x: -150, y: -300)
            Circle()
                .fill(ClubPalette.accent.opacity(0.15))
                .frame(width: 240, height: 240)
                .blur(radius: 66)
                .offset(x: 120, y: -170)
            Circle()
                .fill(ClubPalette.emerald.opacity(0.12))
                .frame(width: 255, height: 255)
                .blur(radius: 74)
                .offset(x: 130, y: 330)
        }
    }
}

struct ClubCard<Content: View>: View {
    let paddingAmount: CGFloat
    @ViewBuilder var content: Content

    init(padding: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.paddingAmount = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(paddingAmount)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(ClubPalette.card.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(ClubPalette.cardBorder, lineWidth: 1)
            )
    }
}

struct ClubHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 31, weight: .bold, design: .serif))
                .foregroundStyle(ClubPalette.white)
            Text(subtitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ClubPalette.mutedText)
        }
    }
}

struct BalancePill: View {
    let points: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 18))
                .foregroundStyle(ClubPalette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(points.formattedWithSeparator)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(ClubPalette.accent)
                Text("Club Points")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ClubPalette.mutedText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule(style: .continuous).fill(ClubPalette.background.opacity(0.75)))
        .overlay(Capsule(style: .continuous).stroke(ClubPalette.accentStrong.opacity(0.7), lineWidth: 1))
    }
}

struct SolidCTAButton: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(ClubPalette.background)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                LinearGradient(
                    colors: [ClubPalette.accent, ClubPalette.accentStrong],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct SectionTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .serif))
                .foregroundStyle(ClubPalette.white)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ClubPalette.mutedText)
            }
        }
    }
}

struct ClubTabBar: View {
    @Binding var selectedTab: ClubTab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ClubTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 15, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(selectedTab == tab ? ClubPalette.accent : ClubPalette.mutedText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(selectedTab == tab ? ClubPalette.accent.opacity(0.12) : .clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Capsule(style: .continuous).fill(ClubPalette.surface.opacity(0.96)))
        .overlay(Capsule(style: .continuous).stroke(ClubPalette.cardBorder, lineWidth: 1))
        .shadow(color: ClubPalette.background.opacity(0.8), radius: 18, x: 0, y: 12)
    }
}

struct ClubScreen: View {
    @ObservedObject var store: ClubStore
    let onOpenGames: () -> Void

    private var notes: [FeedNote] {
        [
            FeedNote(title: "Collection Updated", text: "New rare items are ready to unlock in your collection."),
            FeedNote(title: "Daily Task Ready", text: "Complete today’s challenge and keep your streak active."),
            FeedNote(title: "Game Circuit Active", text: "Finish 3 different games to complete today’s route.")
        ]
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    ClubHeader(title: "Royal Fortune Club", subtitle: "Private Skill Arcade")
                    Spacer()
                    BalancePill(points: store.balancePoints)
                }

                ClubCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Tonight’s Focus")
                            .font(.system(size: 24, weight: .bold, design: .serif))
                            .foregroundStyle(ClubPalette.white)
                        Text("Start your focus session and complete 3 skill games.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(ClubPalette.mutedText)
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Session Goal")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(ClubPalette.mutedText)
                                Text("\(store.dailyProgress)/3 games")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(ClubPalette.white)
                            }
                            Spacer()
                            Text("Reward +1 500")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ClubPalette.background)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(ClubPalette.accent))
                        }
                        Button(action: onOpenGames) {
                            SolidCTAButton(title: "Start Session")
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 10) {
                    statusCard(title: "Rank", value: store.activeRank.title)
                    statusCard(title: "Streak", value: "\(store.streak) Day")
                    statusCard(title: "Focus", value: store.currentBoost == nil ? "Ready" : "Boosted")
                }

                SectionTitle(title: "Featured Challenge", subtitle: "Limited club event")
                    .padding(.top, 10)

                ClubCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Spotlight Session")
                            .font(.system(size: 23, weight: .bold, design: .serif))
                            .foregroundStyle(ClubPalette.white)
                        Text("Complete any game in Spotlight Session to unlock a fixed bonus reward.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(ClubPalette.mutedText)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Session Bonus")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(ClubPalette.mutedText)
                                Text("+900 Club Points")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(ClubPalette.white)
                            }
                            Spacer()
                            Text("Fixed reward")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ClubPalette.emerald)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(ClubPalette.emerald.opacity(0.16)))
                        }
                        Button(action: onOpenGames) {
                            SolidCTAButton(title: "Join Challenge")
                        }
                        .buttonStyle(.plain)
                    }
                }

                SectionTitle(title: "Club Notes", subtitle: "")
                    .padding(.top, 8)

                ForEach(notes) { note in
                    ClubCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(note.title)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(ClubPalette.white)
                            Text(note.text)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(ClubPalette.mutedText)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 20)
        }
    }

    private func statusCard(title: String, value: String) -> some View {
        ClubCard(padding: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ClubPalette.mutedText)
                Text(value)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ClubPalette.white)
            }
        }
    }
}

struct GamesScreen: View {
    @ObservedObject var store: ClubStore
    let onOpenGame: (SkillGame) -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                ClubHeader(title: "Skill Games", subtitle: "Challenge your timing, memory, and focus")
                    .padding(.top, 10)

                ClubCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Daily Circuit")
                            .font(.system(size: 24, weight: .bold, design: .serif))
                            .foregroundStyle(ClubPalette.white)
                        Text("Complete 3 different games to finish today’s circuit.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(ClubPalette.mutedText)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Progress")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(ClubPalette.mutedText)
                                Text("\(store.todayCircuitCount)/3")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(ClubPalette.white)
                            }
                            Spacer()
                            Text(store.hasCompletedDailyTask ? "Complete" : "In Progress")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ClubPalette.background)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(ClubPalette.accent))
                        }
                        Text("Bonus: +1 500 Club Points")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ClubPalette.emerald)
                    }
                }

                SectionTitle(title: "Game Library", subtitle: "8 available")
                    .padding(.top, 8)

                ForEach(SkillGame.allCases) { game in
                    Button {
                        onOpenGame(game)
                    } label: {
                        GameRowCard(game: game, best: store.state.bestScores[game.rawValue] ?? 0)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
}

struct GameRowCard: View {
    let game: SkillGame
    let best: Int

    var body: some View {
        ClubCard {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(ClubPalette.accent.opacity(0.18))
                        .frame(width: 48, height: 48)
                    Image(systemName: game.icon)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(ClubPalette.accent)
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text(game.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(ClubPalette.white)
                    Text(game.subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ClubPalette.mutedText)
                    HStack(spacing: 8) {
                        ForEach(game.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(ClubPalette.blueAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(ClubPalette.blueAccent.opacity(0.14)))
                        }
                    }
                    HStack {
                        Text("Best: \(best == 0 ? "-" : "\(best)%")")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ClubPalette.mutedText)
                        Spacer()
                        Text("Reward: +\(game.reward)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(ClubPalette.accent)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ClubPalette.mutedText)
            }
        }
    }
}

struct CollectionScreen: View {
    @ObservedObject var store: ClubStore
    let onOpenRelic: (Relic) -> Void

    private let grid = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                ClubHeader(title: "Collection", subtitle: "Your private rewards archive")
                    .padding(.top, 10)

                ClubCard {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Club Balance")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ClubPalette.mutedText)
                        Text(store.balancePoints.formattedWithSeparator)
                            .font(.system(size: 38, weight: .bold, design: .serif))
                            .foregroundStyle(ClubPalette.accent)
                        Text("available Club Points")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ClubPalette.mutedText)
                        Text("Earn more by completing games and tasks.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ClubPalette.mutedText)
                    }
                }

                SectionTitle(title: "Royal Relics", subtitle: "Unlock rare items through progress")
                    .padding(.top, 6)

                LazyVGrid(columns: grid, spacing: 12) {
                    ForEach(Relic.all) { relic in
                        Button {
                            onOpenRelic(relic)
                        } label: {
                            RelicCard(relic: relic, unlocked: store.isRelicUnlocked(relic))
                        }
                        .buttonStyle(.plain)
                    }
                }

                ClubCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Collection Bonus")
                            .font(.system(size: 22, weight: .bold, design: .serif))
                            .foregroundStyle(ClubPalette.white)
                        Text("Unlock 4 Royal Relics to receive a new member title.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ClubPalette.mutedText)
                        HStack {
                            Text("\(store.relicsFound)/4")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(ClubPalette.white)
                            Spacer()
                            Text(store.relicsFound >= 4 ? "Bonus Active" : "In Progress")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ClubPalette.background)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(ClubPalette.accent))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
        }
    }
}

struct RelicCard: View {
    let relic: Relic
    let unlocked: Bool

    var body: some View {
        ClubCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(ClubPalette.background.opacity(0.7))
                        .frame(height: 90)
                    Image(systemName: relic.symbol)
                        .font(.system(size: 35))
                        .foregroundStyle(unlocked ? ClubPalette.accent : ClubPalette.mutedText)

                    if !unlocked {
                        Rectangle()
                            .fill(ClubPalette.background.opacity(0.42))
                        Image(systemName: "lock.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(ClubPalette.mutedText)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text(relic.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ClubPalette.white)
                Text(unlocked ? "Unlocked" : "Locked")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(unlocked ? ClubPalette.emerald : ClubPalette.mutedText)
                Text(relic.requirement)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ClubPalette.mutedText)
            }
        }
    }
}

struct TasksScreen: View {
    @ObservedObject var store: ClubStore
    let onOpenGames: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                ClubHeader(title: "Tasks", subtitle: "Daily and weekly progress rewards")
                    .padding(.top, 10)

                ClubCard {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Daily Focus Task")
                            .font(.system(size: 22, weight: .bold, design: .serif))
                            .foregroundStyle(ClubPalette.white)
                        Text("Complete 3 skill games and claim your club reward.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ClubPalette.mutedText)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Progress")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(ClubPalette.mutedText)
                                Text("\(store.dailyProgress)/3")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(ClubPalette.white)
                            }
                            Spacer()
                            Text("+1 500")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ClubPalette.background)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(ClubPalette.accent))
                        }
                        Button(action: onOpenGames) {
                            SolidCTAButton(title: "Open Games")
                        }
                        .buttonStyle(.plain)
                    }
                }

                ClubCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Royal Streak")
                            .font(.system(size: 22, weight: .bold, design: .serif))
                            .foregroundStyle(ClubPalette.white)
                        Text("Return every day to unlock bigger rewards.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ClubPalette.mutedText)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                streakDay("Day 1", "+500", active: store.streak == 1)
                                streakDay("Day 2", "+800", active: store.streak == 2)
                                streakDay("Day 3", "+1 100", active: store.streak == 3)
                                streakDay("Day 4", "+1 500", active: store.streak == 4)
                                streakDay("Day 5", "+2 000", active: store.streak == 5)
                                streakDay("Day 6", "+2 700", active: store.streak == 6)
                                streakDay("Day 7", "+3 500", active: store.streak >= 7)
                            }
                        }
                        Button {
                            store.claimDailyStreakReward()
                        } label: {
                            SolidCTAButton(title: store.canClaimDaily ? "Claim Daily Reward" : "Already Claimed")
                                .opacity(store.canClaimDaily ? 1 : 0.6)
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.canClaimDaily)
                    }
                }

                ClubCard {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Focus Boost")
                            .font(.system(size: 22, weight: .bold, design: .serif))
                            .foregroundStyle(ClubPalette.white)
                        Text(store.currentBoost == nil ? "Ready to claim" : "Active: \(store.currentBoost?.title ?? "-")")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ClubPalette.emerald)
                        Text("Activate a temporary boost before your next game.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ClubPalette.mutedText)
                        HStack(spacing: 8) {
                            boostPill("Precision Boost")
                            boostPill("Focus Boost")
                            boostPill("Reward Boost")
                        }
                        Button {
                            store.claimBoost()
                        } label: {
                            SolidCTAButton(title: store.currentBoost == nil ? "Claim Boost" : "Boost Active")
                                .opacity(store.currentBoost == nil ? 1 : 0.6)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.currentBoost != nil)
                    }
                }

                ClubCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Weekly Route")
                            .font(.system(size: 22, weight: .bold, design: .serif))
                            .foregroundStyle(ClubPalette.white)
                        Text("Complete 15 games this week to unlock a rare collection item.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ClubPalette.mutedText)
                        HStack {
                            Text("\(store.weeklyProgress)/15")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(ClubPalette.white)
                            Spacer()
                            Text("Reward: Royal Key")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ClubPalette.accent)
                        }
                        ProgressBar(value: min(1, Double(store.weeklyProgress) / 15.0))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }

    private func streakDay(_ day: String, _ reward: String, active: Bool) -> some View {
        VStack(spacing: 5) {
            Text(day)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? ClubPalette.background : ClubPalette.mutedText)
            Text(reward)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(active ? ClubPalette.background : ClubPalette.white)
        }
        .frame(width: 72, height: 58)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(active ? ClubPalette.accent : ClubPalette.background.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(active ? ClubPalette.accentStrong : ClubPalette.cardBorder, lineWidth: 1)
        )
    }

    private func boostPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ClubPalette.blueAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(ClubPalette.blueAccent.opacity(0.12)))
    }
}

struct ProfileScreen: View {
    @ObservedObject var store: ClubStore
    let onOpenGames: () -> Void

    private var stats: [(String, String)] {
        [
            ("Games Played", "\(store.gamesPlayed)"),
            ("Club Balance", store.balancePoints.formattedWithSeparator),
            ("Daily Task", "\(store.dailyProgress)/3"),
            ("Current Streak", "\(store.streak) Day"),
            ("Relics Found", "\(store.relicsFound)"),
            ("Best Game", store.bestGameTitle),
            ("Favorite Session", store.favoriteSession)
        ]
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                ClubHeader(title: "Club Profile", subtitle: "Member status")
                    .padding(.top, 10)

                ClubCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(store.activeRank.title)
                            .font(.system(size: 26, weight: .bold, design: .serif))
                            .foregroundStyle(ClubPalette.white)
                        Text("\(store.prestigePoints)")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(ClubPalette.accent)
                        Text("total prestige points")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ClubPalette.mutedText)
                        Text("Next Rank: \(store.activeRank.nextTitle)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ClubPalette.mutedText)
                        ProgressBar(value: store.nextRankProgress)
                        HStack {
                            Text("\(Int(store.nextRankProgress * 100))%")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ClubPalette.white)
                            Spacer()
                            Text("View Ranks")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ClubPalette.background)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(ClubPalette.accent))
                        }
                    }
                }

                ForEach(stats, id: \.0) { stat in
                    ClubCard(padding: 14) {
                        HStack {
                            Text(stat.0)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(ClubPalette.mutedText)
                            Spacer()
                            Text(stat.1)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(ClubPalette.white)
                        }
                    }
                }

                ClubCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Current Objective")
                            .font(.system(size: 22, weight: .bold, design: .serif))
                            .foregroundStyle(ClubPalette.white)
                        Text("Complete 3 skill games and claim +1 500 Club Points.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ClubPalette.mutedText)
                        Button(action: onOpenGames) {
                            SolidCTAButton(title: "Go to Games")
                        }
                        .buttonStyle(.plain)
                    }
                }

                ClubCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Royal Rank Path")
                            .font(.system(size: 22, weight: .bold, design: .serif))
                            .foregroundStyle(ClubPalette.white)
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(RankInfo.ranks.indices, id: \.self) { index in
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(index == RankInfo.ranks.firstIndex(where: { $0.title == store.activeRank.title }) ? ClubPalette.accent : ClubPalette.accentStrong.opacity(0.4))
                                        .frame(width: 10, height: 10)
                                    Text(RankInfo.ranks[index].title)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(ClubPalette.white)
                                }
                            }
                        }
                    }
                }

                ClubCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Club Rules")
                            .font(.system(size: 22, weight: .bold, design: .serif))
                            .foregroundStyle(ClubPalette.white)
                        Text("Royal Fortune Club is a private skill-based arcade experience. No real-money betting. No cash rewards. Club Points are used only for in-app progression.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ClubPalette.mutedText)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }
}

struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(ClubPalette.background.opacity(0.8))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [ClubPalette.accent, ClubPalette.accentStrong],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 8)
    }
}

struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        ClubCard(padding: 24) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(ClubPalette.accent.opacity(0.18))
                            .frame(width: 66, height: 66)
                        Image(systemName: page.icon)
                            .font(.system(size: 30))
                            .foregroundStyle(ClubPalette.accent)
                    }
                    Spacer()
                }

                Text(page.title)
                    .font(.system(size: 32, weight: .bold, design: .serif))
                    .foregroundStyle(ClubPalette.white)
                Text(page.subtitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ClubPalette.accent)
                Text(page.text)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(ClubPalette.mutedText)
                    .fixedSize(horizontal: false, vertical: true)

                if !page.bullets.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(page.bullets, id: \.self) { item in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(ClubPalette.emerald)
                                    .frame(width: 7, height: 7)
                                Text(item)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(ClubPalette.white)
                            }
                        }
                    }
                    .padding(.top, 3)
                }
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.vertical, 28)
    }
}

struct GameDetailView: View {
    let game: SkillGame
    @ObservedObject var store: ClubStore

    @State private var isPlaying = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            ClubBackground().ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(ClubPalette.white)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(ClubPalette.surface.opacity(0.9)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    ClubHeader(title: game.title, subtitle: "\(game.tags.first ?? "Skill") Challenge")

                    ClubCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(game.subtitle)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(ClubPalette.mutedText)
                            infoRow(label: "Difficulty", value: game.difficulty)
                            infoRow(label: "Reward", value: "+\(game.reward) Club Points")
                            infoRow(label: "Best Score", value: bestValue)
                        }
                    }

                    Button {
                        isPlaying = true
                    } label: {
                        SolidCTAButton(title: "Play Game")
                    }
                    .buttonStyle(.plain)

                    ClubCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Rules")
                                .font(.system(size: 20, weight: .bold, design: .serif))
                                .foregroundStyle(ClubPalette.white)
                            ForEach(game.rules, id: \.self) { rule in
                                Text(rule)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(ClubPalette.mutedText)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .fullScreenCover(isPresented: $isPlaying) {
            GameSessionView(game: game, store: store)
        }
    }

    private var bestValue: String {
        let best = store.state.bestScores[game.rawValue] ?? 0
        return best == 0 ? "No score yet" : "\(best)%"
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ClubPalette.mutedText)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ClubPalette.white)
        }
    }
}

struct GameSessionResult {
    let success: Bool
    let score: Int
    let reward: Int
    let prestige: Int
}

struct GameSessionView: View {
    let game: SkillGame
    @ObservedObject var store: ClubStore

    @Environment(\.dismiss) private var dismiss
    @State private var result: GameSessionResult?

    var body: some View {
        ZStack {
            ClubBackground().ignoresSafeArea()

            VStack(spacing: 12) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(ClubPalette.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(ClubPalette.surface.opacity(0.9)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(game.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(ClubPalette.white)
                    Spacer()
                    Color.clear.frame(width: 32, height: 32)
                }
                .padding(.horizontal, 16)

                if let result {
                    resultView(result)
                } else {
                    gameplayView
                }
            }
            .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var gameplayView: some View {
        switch game {
        case .pulseTap:
            PulseTapGame { score, success in finish(score: score, success: success) }
        case .patternMatch:
            PatternMatchGame { score, success in finish(score: score, success: success) }
        case .focusOrbit:
            FocusOrbitGame { score, success in finish(score: score, success: success) }
        case .pathRelay:
            PathRelayGame { score, success in finish(score: score, success: success) }
        case .sequenceEcho:
            SequenceEchoGame { score, success in finish(score: score, success: success) }
        case .signalHunt:
            SignalHuntGame { score, success in finish(score: score, success: success) }
        case .mirrorRelay:
            MirrorRelayGame { score, success in finish(score: score, success: success) }
        case .logicFilter:
            LogicFilterGame { score, success in finish(score: score, success: success) }
        }
    }

    private func finish(score: Int, success: Bool) {
        store.completeGame(game: game, score: score, success: success)
        let reward = success ? game.reward : 0
        let prestige = success ? 25 : 0
        result = GameSessionResult(success: success, score: score, reward: reward, prestige: prestige)
    }

    private func resultView(_ result: GameSessionResult) -> some View {
        VStack(spacing: 14) {
            Text(result.success ? "Game Complete" : "Game Failed")
                .font(.system(size: 30, weight: .bold, design: .serif))
                .foregroundStyle(ClubPalette.white)

            ClubCard {
                VStack(alignment: .leading, spacing: 9) {
                    Text(game.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(ClubPalette.white)
                    Text("Accuracy \(result.score)%")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(result.success ? ClubPalette.emerald : ClubPalette.mutedText)
                    if result.success {
                        Text("Rewards")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ClubPalette.mutedText)
                        Text("+\(result.reward) Club Points")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(ClubPalette.accent)
                        Text("+\(result.prestige) Prestige Points")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(ClubPalette.emerald)
                    } else {
                        Text("The required accuracy was not reached. Retry to complete the circuit.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ClubPalette.mutedText)
                    }
                }
            }

            Button {
                dismiss()
            } label: {
                SolidCTAButton(title: result.success ? "Continue" : "Retry Later")
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }
}

// MARK: - Mini Games

struct PulseTapGame: View {
    let onFinish: (Int, Bool) -> Void

    @State private var position: Double = 0.1
    @State private var direction: Double = 1
    @State private var targetCenter: Double = 0.6
    @State private var round = 1
    @State private var totalScore = 0.0

    private let timer = Timer.publish(every: 0.018, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            Text("Round \(round)/3")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(ClubPalette.white)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ClubPalette.background.opacity(0.8)).frame(height: 24)

                    Capsule()
                        .fill(ClubPalette.accent.opacity(0.4))
                        .frame(width: geo.size.width * 0.22, height: 24)
                        .offset(x: max(0, min(geo.size.width - geo.size.width * 0.22, geo.size.width * (targetCenter - 0.11))))

                    Circle()
                        .fill(ClubPalette.white)
                        .frame(width: 22, height: 22)
                        .offset(x: max(1, min(geo.size.width - 22, geo.size.width * position - 11)))
                }
            }
            .frame(height: 24)
            .padding(.horizontal, 16)
            .onReceive(timer) { _ in
                var next = position + (0.012 * direction)
                if next > 1 {
                    next = 1
                    direction = -1
                } else if next < 0 {
                    next = 0
                    direction = 1
                }
                position = next
            }

            Button {
                let delta = abs(position - targetCenter)
                let score = max(0, Int((1 - delta / 0.35) * 100))
                totalScore += Double(score)

                if round == 3 {
                    let avg = Int(totalScore / 3.0)
                    onFinish(avg, avg >= 70)
                } else {
                    round += 1
                    targetCenter = Double.random(in: 0.2...0.8)
                }
            } label: {
                Text("Tap Now")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(ClubPalette.background)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Capsule().fill(ClubPalette.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)

            Spacer()
        }
        .padding(.top, 12)
    }
}

struct PatternMatchGame: View {
    let onFinish: (Int, Bool) -> Void

    @State private var values: [Int] = [0,0,1,1,2,2].shuffled()
    @State private var revealed: Set<Int> = []
    @State private var matched: Set<Int> = []
    @State private var firstPick: Int?
    @State private var moves = 0
    @State private var locked = false

    var body: some View {
        VStack(spacing: 18) {
            Text("Moves: \(moves)/12")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(ClubPalette.white)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(0..<values.count, id: \.self) { index in
                    Button {
                        tapCard(index)
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(cardColor(index))
                                .frame(height: 84)
                            Text(cardText(index))
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(ClubPalette.white)
                        }
                    }
                    .disabled(locked || matched.contains(index) || revealed.contains(index))
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)

            Spacer()
        }
        .padding(.top, 12)
    }

    private func cardText(_ idx: Int) -> String {
        if matched.contains(idx) || revealed.contains(idx) {
            return ["▲", "●", "■"][values[idx]]
        }
        return "?"
    }

    private func cardColor(_ idx: Int) -> Color {
        if matched.contains(idx) { return ClubPalette.emerald.opacity(0.35) }
        if revealed.contains(idx) { return ClubPalette.accent.opacity(0.35) }
        return ClubPalette.surface
    }

    private func tapCard(_ index: Int) {
        revealed.insert(index)
        if let first = firstPick {
            moves += 1
            locked = true
            if values[first] == values[index] {
                matched.insert(first)
                matched.insert(index)
                firstPick = nil
                locked = false
                checkFinish()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    revealed.remove(first)
                    revealed.remove(index)
                    firstPick = nil
                    locked = false
                    if moves >= 12 {
                        onFinish(score(), false)
                    }
                }
            }
        } else {
            firstPick = index
        }
    }

    private func checkFinish() {
        if matched.count == values.count {
            let s = score()
            onFinish(s, s >= 70)
        }
    }

    private func score() -> Int {
        let matchRatio = Double(matched.count) / Double(values.count)
        let penalty = max(0, moves - 3) * 5
        return max(0, min(100, Int(matchRatio * 100) - penalty))
    }
}

struct FocusOrbitGame: View {
    let onFinish: (Int, Bool) -> Void

    @State private var angle: Double = 0
    @State private var round = 1
    @State private var targetAngle: Double = Double.random(in: 20...320)
    @State private var total = 0.0

    private let timer = Timer.publish(every: 0.016, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            Text("Round \(round)/3")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(ClubPalette.white)

            ZStack {
                Circle()
                    .stroke(ClubPalette.cardBorder, lineWidth: 14)
                    .frame(width: 220, height: 220)

                Arc(startAngle: .degrees(targetAngle - 25), endAngle: .degrees(targetAngle + 25), clockwise: false)
                    .stroke(ClubPalette.accent, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .frame(width: 220, height: 220)

                Circle()
                    .fill(ClubPalette.white)
                    .frame(width: 18, height: 18)
                    .offset(y: -110)
                    .rotationEffect(.degrees(angle))
            }
            .onReceive(timer) { _ in
                angle = (angle + 2.3).truncatingRemainder(dividingBy: 360)
            }

            Button {
                let delta = angularDistance(angle, targetAngle)
                let score = max(0, Int((1 - delta / 100) * 100))
                total += Double(score)
                if round == 3 {
                    let avg = Int(total / 3)
                    onFinish(avg, avg >= 70)
                } else {
                    round += 1
                    targetAngle = Double.random(in: 20...320)
                }
            } label: {
                Text("Stop")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(ClubPalette.background)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Capsule().fill(ClubPalette.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)

            Spacer()
        }
        .padding(.top, 12)
    }

    private func angularDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}

struct PathRelayGame: View {
    let onFinish: (Int, Bool) -> Void

    private let directions = ["↑", "→", "↓", "←"]
    @State private var sequence: [Int] = Array((0..<4).map { _ in Int.random(in: 0...3) })
    @State private var index = 0
    @State private var mistakes = 0

    var body: some View {
        VStack(spacing: 20) {
            Text("Repeat the path")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(ClubPalette.white)

            Text(sequence.map { directions[$0] }.joined(separator: " "))
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(ClubPalette.accent)
                .padding(.top, 8)

            Text("Step \(index + 1)/\(sequence.count)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ClubPalette.mutedText)

            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { idx in
                    Button {
                        tap(idx)
                    } label: {
                        Text(directions[idx])
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(ClubPalette.white)
                            .frame(width: 62, height: 62)
                            .background(RoundedRectangle(cornerRadius: 14).fill(ClubPalette.surface))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(ClubPalette.cardBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .padding(.top, 12)
    }

    private func tap(_ idx: Int) {
        if sequence[index] == idx {
            index += 1
            if index == sequence.count {
                let score = max(0, 100 - mistakes * 20)
                onFinish(score, score >= 70)
            }
        } else {
            mistakes += 1
            if mistakes >= 3 {
                onFinish(max(0, 100 - mistakes * 20), false)
            }
        }
    }
}

struct SequenceEchoGame: View {
    let onFinish: (Int, Bool) -> Void

    @State private var sequence: [Int] = [Int.random(in: 0...3), Int.random(in: 0...3), Int.random(in: 0...3), Int.random(in: 0...3)]
    @State private var index = 0
    @State private var showIndex: Int? = nil
    @State private var showing = true
    @State private var mistakes = 0

    let colors: [Color] = [
        ClubPalette.accent,
        ClubPalette.blueAccent,
        ClubPalette.emerald,
        Color.orange.opacity(0.85)
    ]

    var body: some View {
        VStack(spacing: 18) {
            Text(showing ? "Watch the sequence" : "Repeat the sequence")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(ClubPalette.white)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(0..<4, id: \.self) { idx in
                    RoundedRectangle(cornerRadius: 14)
                        .fill((showIndex == idx ? colors[idx] : colors[idx].opacity(0.35)))
                        .frame(height: 92)
                        .overlay(Text("\(idx + 1)").foregroundStyle(ClubPalette.white).font(.headline))
                        .onTapGesture {
                            if !showing { tap(idx) }
                        }
                }
            }
            .padding(.horizontal, 16)

            Text("Step \(index + 1)/\(sequence.count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ClubPalette.mutedText)

            Spacer()
        }
        .padding(.top, 12)
        .task {
            await playSequence()
            showing = false
        }
    }

    private func tap(_ idx: Int) {
        if idx == sequence[index] {
            index += 1
            if index == sequence.count {
                let score = max(0, 100 - mistakes * 20)
                onFinish(score, score >= 70)
            }
        } else {
            mistakes += 1
            if mistakes >= 3 {
                onFinish(max(0, 100 - mistakes * 20), false)
            }
        }
    }

    private func playSequence() async {
        for item in sequence {
            showIndex = item
            try? await Task.sleep(nanoseconds: 500_000_000)
            showIndex = nil
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}

struct SignalHuntGame: View {
    let onFinish: (Int, Bool) -> Void

    @State private var step = 0
    @State private var target = Bool.random()
    @State private var hits = 0
    @State private var falseHits = 0

    var body: some View {
        VStack(spacing: 20) {
            Text("Event \(step + 1)/10")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(ClubPalette.white)

            Circle()
                .fill(target ? ClubPalette.emerald : Color.red.opacity(0.65))
                .frame(width: 140, height: 140)
                .overlay(
                    Text(target ? "TRUE" : "FALSE")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(ClubPalette.white)
                )

            HStack(spacing: 12) {
                Button {
                    if target { hits += 1 } else { falseHits += 1 }
                    advance()
                } label: {
                    Text("Catch")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(ClubPalette.background)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Capsule().fill(ClubPalette.accent))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    if target { falseHits += 1 }
                    advance()
                } label: {
                    Text("Skip")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(ClubPalette.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Capsule().fill(ClubPalette.surface))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            Spacer()
        }
        .padding(.top, 12)
    }

    private func advance() {
        step += 1
        if step >= 10 {
            let score = max(0, Int((Double(hits) / 10.0) * 100) - falseHits * 5)
            onFinish(score, score >= 70)
        } else {
            target = Bool.random()
        }
    }
}

struct MirrorRelayGame: View {
    let onFinish: (Int, Bool) -> Void

    private let arrows = ["↑", "→", "↓", "←"]
    @State private var sequence: [Int] = Array((0..<5).map { _ in Int.random(in: 0...3) })
    @State private var index = 0
    @State private var mistakes = 0

    var body: some View {
        VStack(spacing: 18) {
            Text("Mirror each command")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(ClubPalette.white)

            Text("Rule: ↑↔↓, ←↔→")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ClubPalette.mutedText)

            Text(sequence.map { arrows[$0] }.joined(separator: " "))
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(ClubPalette.accent)
                .padding(.top, 6)

            Text("Step \(index + 1)/\(sequence.count)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ClubPalette.mutedText)

            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { idx in
                    Button {
                        tap(idx)
                    } label: {
                        Text(arrows[idx])
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(ClubPalette.white)
                            .frame(width: 62, height: 62)
                            .background(RoundedRectangle(cornerRadius: 14).fill(ClubPalette.surface))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(ClubPalette.cardBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .padding(.top, 12)
    }

    private func mirrorOf(_ value: Int) -> Int {
        switch value {
        case 0: return 2
        case 2: return 0
        case 1: return 3
        default: return 1
        }
    }

    private func tap(_ idx: Int) {
        let expected = mirrorOf(sequence[index])
        if idx == expected {
            index += 1
            if index == sequence.count {
                let score = max(0, 100 - mistakes * 18)
                onFinish(score, score >= 70)
            }
        } else {
            mistakes += 1
            if mistakes >= 3 {
                onFinish(max(0, 100 - mistakes * 18), false)
            }
        }
    }
}

struct LogicFilterGame: View {
    let onFinish: (Int, Bool) -> Void

    @State private var step = 0
    @State private var current = Int.random(in: 2...40)
    @State private var targetRulePrime = true
    @State private var correctActions = 0
    @State private var wrongActions = 0

    private var maxSteps: Int { 12 }

    var body: some View {
        VStack(spacing: 20) {
            Text("Event \(step + 1)/\(maxSteps)")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(ClubPalette.white)

            Text(targetRulePrime ? "Rule: Catch prime numbers" : "Rule: Catch multiples of 3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ClubPalette.mutedText)

            RoundedRectangle(cornerRadius: 20)
                .fill(ClubPalette.surface)
                .frame(width: 170, height: 150)
                .overlay(
                    Text("\(current)")
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .foregroundStyle(ClubPalette.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(ClubPalette.cardBorder, lineWidth: 1)
                )

            HStack(spacing: 12) {
                Button {
                    let shouldCatch = isMatch(current)
                    if shouldCatch { correctActions += 1 } else { wrongActions += 1 }
                    advance()
                } label: {
                    Text("Catch")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(ClubPalette.background)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Capsule().fill(ClubPalette.accent))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    let shouldCatch = isMatch(current)
                    if shouldCatch { wrongActions += 1 } else { correctActions += 1 }
                    advance()
                } label: {
                    Text("Pass")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(ClubPalette.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Capsule().fill(ClubPalette.surface))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            Spacer()
        }
        .padding(.top, 12)
    }

    private func isMatch(_ value: Int) -> Bool {
        if targetRulePrime {
            if value < 2 { return false }
            for i in 2...Int(Double(value).squareRoot()) {
                if value % i == 0 { return false }
            }
            return true
        }
        return value % 3 == 0
    }

    private func advance() {
        step += 1
        if step >= maxSteps {
            let base = Int((Double(correctActions) / Double(maxSteps)) * 100)
            let score = max(0, base - wrongActions * 6)
            onFinish(score, score >= 70)
        } else {
            current = Int.random(in: 2...40)
            if step % 4 == 0 {
                targetRulePrime.toggle()
            }
        }
    }
}

struct Arc: Shape {
    var startAngle: Angle
    var endAngle: Angle
    var clockwise: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: rect.width / 2,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: clockwise
        )
        return path
    }
}

struct RelicDetailView: View {
    let relic: Relic
    let unlocked: Bool

    var body: some View {
        ZStack {
            ClubBackground().ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(relic.title)
                        .font(.system(size: 26, weight: .bold, design: .serif))
                        .foregroundStyle(ClubPalette.white)
                    Spacer()
                    Text(unlocked ? "Unlocked" : "Locked")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(unlocked ? ClubPalette.emerald : ClubPalette.mutedText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(ClubPalette.background.opacity(0.7)))
                }

                ClubCard {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(ClubPalette.background.opacity(0.76))
                                .frame(width: 68, height: 68)
                            Image(systemName: relic.symbol)
                                .font(.system(size: 33))
                                .foregroundStyle(unlocked ? ClubPalette.accent : ClubPalette.mutedText)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Requirement")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(ClubPalette.mutedText)
                            Text(relic.requirement)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(ClubPalette.white)
                        }
                    }
                }

                Text(unlocked ? "This relic is now part of your permanent collection." : "Complete the requirement in your club journey to unlock this relic.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ClubPalette.mutedText)

                Spacer()
            }
            .padding(16)
        }
    }
}

extension Int {
    var formattedWithSeparator: String {
        let formatter = NumberFormatter()
        formatter.groupingSeparator = " "
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}

extension Color {
    init(hex: String) {
        let value = hex.replacingOccurrences(of: "#", with: "")
        var number: UInt64 = 0
        Scanner(string: value).scanHexInt64(&number)
        let red = Double((number >> 16) & 0xFF) / 255
        let green = Double((number >> 8) & 0xFF) / 255
        let blue = Double(number & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

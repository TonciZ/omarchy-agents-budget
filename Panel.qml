import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.tonciz.agents-budget"
  ipcTarget: "io.github.tonciz.agents-budget"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color barBackground: bar ? bar.background : Commons.Color.bar.background
  // The shell has no warning color, so the glance pill reads the theme's own
  // yellow from colors.toml.
  property color warning: "#c8b45a"
  FileView {
    path: Commons.Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var match = text().match(/^\s*(?:yellow|color3)\s*=\s*["']?(#[0-9A-Fa-f]{6})/m)
      if (match) root.warning = match[1]
    }
  }
  readonly property color surface: Commons.Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Commons.Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var providers: usage.enabledProviders
  // The selection follows the provider, not the slot it happens to sit in: a
  // provider whose first scan lands while the panel is open would otherwise
  // shift the list underneath you and swap out what you were reading.
  property string selectedProviderId: ""
  readonly property int providerIndex: {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].providerId === selectedProviderId) return i
    return 0
  }
  readonly property var provider: providers.length > 0 ? providers[providerIndex] : null

  property bool cursorActive: false

  // Countdowns and "updated" read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  readonly property var limits: limitWindows(provider)
  readonly property var models: modelRows(provider)
  readonly property var headline: bindingWindow(provider)
  readonly property var balance: provider ? (provider.balance || null) : null
  // A prepaid account runs low the way a subscription window fills up: the
  // last 10% of the funded credits lights the same alarm.
  readonly property bool balanceAlarming: !!balance && balance.funded > 0
    && balance.remaining / balance.funded <= 0.1
  readonly property bool alarming: limits.some(function(w) { return limitLevel(w) === 2 }) || balanceAlarming

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function selectProvider(index) {
    if (providers.length === 0) return
    var wrapped = ((index % providers.length) + providers.length) % providers.length
    selectedProviderId = providers[wrapped].providerId
  }

  function refreshNow() {
    usage.refreshAll(true)
  }

  function launchAgent() {
    if (root.bar) root.bar.run("omarchy-agent --pick")
    root.close()
  }

  // ---------------------------------------------------------------- limits
  //
  // Both providers report the same two shapes: a short rolling session window
  // and a long weekly one. Everything below normalizes them into one record so
  // the meters and the hero speak a single language.

  // Claude spells its windows out ("Session (5-hour)"), Codex abbreviates
  // them ("5h window", "30m window"). Both have to land on the same record.
  function windowIsLong(text) {
    return text.indexOf("week") >= 0 || text.indexOf("7-day") >= 0 || text.indexOf("seven") >= 0
      || text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0
  }

  function windowSpanMs(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0) return 30 * 24 * 3600 * 1000
    if (windowIsLong(text)) return 7 * 24 * 3600 * 1000
    var hours = text.match(/(\d+)\s*-?\s*h(?:our)?\b/)
    if (hours) return Number(hours[1]) * 3600 * 1000
    var minutes = text.match(/(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b/)
    if (minutes) return Number(minutes[1]) * 60 * 1000
    return 0
  }

  function windowTitle(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0) return "Monthly"
    if (windowIsLong(text)) return "Weekly"
    if (text.indexOf("session") >= 0 || windowSpanMs(label) > 0) return "Session"
    var plain = String(label || "").replace(/\s*\(.*\)\s*/, "").trim()
    return plain === "" ? "Limit" : plain
  }

  // A collector that already knows which window a limit belongs to says so,
  // and that beats reading it back out of the label: a model-scoped limit is
  // titled after its model, and a name like "Opus 5 (1M context)" would parse
  // as a one-minute window.
  function limitWindow(label, percent, resetAt, title) {
    var reset = new Date(String(resetAt || "")).getTime()
    var expired = isFinite(reset) && reset <= root.nowMs
    return {
      title: String(title || "") !== "" ? String(title) : windowTitle(label),
      percent: expired ? 0 : Number(percent),
      resetAt: expired ? "" : String(resetAt || "")
    }
  }

  function limitWindows(p) {
    if (!p) return []
    var out = []
    var list = p.limits || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      var percent = Number(entry.percent)
      if (percent >= 0) out.push(limitWindow(entry.label, percent, entry.resetsAt, entry.title))
    }
    return out
  }

  // The window that decides how much room is left — the fullest one, since
  // that is what stops the next prompt.
  function bindingWindow(p) {
    var windows = limitWindows(p)
    var best = null
    for (var i = 0; i < windows.length; i++) {
      if (!best || windows[i].percent > best.percent) best = windows[i]
    }
    return best
  }

  // Session windows run out fast, so they warn earlier than weekly ones:
  // yellow then red at 70/80% for a session, 85/90% for anything longer.
  function limitLevel(w) {
    if (!w || !(w.percent >= 0)) return 0
    var session = w.title === "Session"
    if (w.percent >= (session ? 0.8 : 0.9)) return 2
    if (w.percent >= (session ? 0.7 : 0.85)) return 1
    return 0
  }

  function limitColor(w, normal) {
    var level = limitLevel(w)
    return level === 2 ? root.urgent : level === 1 ? root.warning : normal
  }

  // ---------------------------------------------------------------- budget
  //
  // A running daily allowance against the weekly window: a seventh of the week
  // per day, with anything unused carried forward. Days run midnight to
  // midnight. The weekly figure at each day's start lives in budget.json so
  // the graph can show what each day used.

  readonly property string budgetPath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/agents/budget.json"
  readonly property real dayMs: 24 * 3600 * 1000
  property var budgetState: ({ reset: "", days: {} })
  property bool budgetLoaded: false

  FileView {
    id: budgetFile
    path: root.budgetPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        if (parsed && parsed.days) root.budgetState = parsed
      } catch (e) {}
      root.budgetLoaded = true
      root.recordBudget()
    }
    onLoadFailed: {
      root.budgetLoaded = true
      root.recordBudget()
    }
  }

  onWeeklyWindowChanged: recordBudget()

  function dateKey(ms) {
    var d = new Date(ms)
    return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0")
  }

  function midnightOf(ms) { var d = new Date(ms); d.setHours(0, 0, 0, 0); return d.getTime() }
  function nextMidnight(ms) { var d = new Date(ms); d.setHours(24, 0, 0, 0); return d.getTime() }

  function recordBudget() {
    var w = root.weeklyWindow
    if (!budgetLoaded || !w || w.resetAt === "") return
    var reset = new Date(w.resetAt).getTime()
    if (!isFinite(reset)) return
    var windowStart = reset - 7 * dayMs
    // The reset time wobbles a little between fetches; a jump of more than
    // an hour is a new window, and the old days no longer count.
    var fresh = !budgetState.reset || Math.abs(new Date(budgetState.reset).getTime() - reset) > 3600000
    var days = {}
    if (!fresh) {
      for (var k in budgetState.days)
        if (k >= dateKey(windowStart)) days[k] = budgetState.days[k]
    }
    var key = dateKey(root.nowMs)
    var day = days[key]
    if (!day) {
      // Today starts where the last recorded day left off, or at zero when
      // the window itself began today.
      var previous = ""
      for (var k2 in days)
        if (k2 < key && k2 > previous) previous = k2
      var start = previous !== "" ? days[previous].last : (windowStart >= midnightOf(root.nowMs) ? 0 : w.percent)
      day = { start: Math.min(start, w.percent), last: w.percent }
    } else if (!fresh && day.last === w.percent) {
      return
    } else {
      day = { start: Math.min(day.start, w.percent), last: w.percent }
    }
    days[key] = day
    budgetState = { reset: w.resetAt, days: days }
    budgetFile.setText(JSON.stringify(budgetState, null, 2) + "\n")
  }

  // Each calendar day from the one the window opened on gets a seventh of the
  // week, and whatever is not used carries forward in full: by the end of day
  // i (0-based) up to (i + 1) / 7 may be used. The window spans eight calendar
  // days, so the last one, the reset day, only has what was saved.
  function budgetCap(index) { return Math.min(1, (index + 1) / 7) }

  readonly property var budgetDays: {
    var w = root.weeklyWindow
    if (!w || w.resetAt === "") return []
    var reset = new Date(w.resetAt).getTime()
    if (!isFinite(reset)) return []
    var windowStart = reset - 7 * dayMs
    var stored = budgetState.days || {}
    var todayKey = dateKey(root.nowMs)
    var out = []
    var index = 0
    for (var begin = midnightOf(windowStart); begin < reset; begin = nextMidnight(begin), index++) {
      var key = dateKey(begin)
      var cap = budgetCap(index)
      var row = { key: key, label: dayName(key), today: key === todayKey, future: key > todayKey,
                  cap: cap, budget: -1, used: -1, over: false }
      var entry = stored[key]
      if (row.future) {
        // What the day has if every day before it ends exactly on budget.
        row.budget = cap - (index > 0 ? budgetCap(index - 1) : 0)
      } else if (row.today) {
        var start = entry ? entry.start : w.percent
        row.budget = cap - start
        row.used = w.percent - start
        row.over = w.percent > cap
        row.total = w.percent
      } else if (entry) {
        row.budget = cap - entry.start
        row.used = Math.max(0, entry.last - entry.start)
        row.over = entry.last > cap + 0.0005
      }
      out.push(row)
    }
    return out
  }

  readonly property var budgetToday: {
    for (var i = 0; i < budgetDays.length; i++)
      if (budgetDays[i].today) return budgetDays[i]
    return null
  }

  function budgetPercent(fraction) {
    var v = Math.round(fraction * 1000) / 10
    return (v % 1 === 0 ? v.toFixed(0) : v.toFixed(1)) + "%"
  }

  function resetMsFor(w) {
    if (!w || w.resetAt === "") return -1
    var ms = new Date(w.resetAt).getTime()
    return isFinite(ms) ? ms - root.nowMs : -1
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  // ---------------------------------------------------------------- balance
  //
  // Prepaid agents report a credit ledger instead of rate-limit windows: the
  // record's balance object carries remaining, funded, and spent amounts.

  function currencyPrefix(currency) {
    var code = String(currency || "USD").toUpperCase()
    if (code === "USD") return "$"
    if (code === "EUR") return "€"
    if (code === "GBP") return "£"
    return code + " "
  }

  function formatMoney(value, currency) {
    var amount = Number(value)
    if (!isFinite(amount)) amount = 0
    return currencyPrefix(currency) + amount.toFixed(2)
  }

  function balanceDetailText(b) {
    if (!b || !(b.funded > 0)) return ""
    var text = formatMoney(b.spent, b.currency) + " spent of " + formatMoney(b.funded, b.currency) + " funded"
    if (b.estimated) text += " · estimated"
    return text
  }

  // ---------------------------------------------------------------- content

  // The plan you pay for, under the name of the tool it pays for. Limits live
  // in their own section; the hero just says what this is.
  function heroMeta(p) {
    if (!p) return ""
    if (String(p.usageStatusText || "") !== "") return p.usageStatusText
    var tier = String(p.tierLabel || "")
    if (tier === "") return "Subscription"
    return tier.charAt(0).toUpperCase() + tier.slice(1)
  }

  // Local calendar date, recomputed from nowMs so a panel left open across
  // midnight moves the "Today" row with the clock.
  function todayDate() {
    var now = new Date(root.nowMs)
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  function dayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
  }

  function dayLabel(date, today) {
    if (today) return "Today"
    return dayName(date)
  }

  function dayTooltip(day, today) {
    if (!day) return ""
    var parsed = new Date(String(day.date) + "T00:00:00")
    var label = isNaN(parsed.getTime())
      ? String(day.date)
      : dayName(day.date) + " " + (parsed.getMonth() + 1) + "/" + parsed.getDate()
    var text = label + " · " + usage.formatTokenCount(Number(day.messageCount || 0)) + " tokens"
    // Prompt and session counts only exist for today, so they ride along here
    // instead of taking a section of their own. Billing-API agents never
    // count prompts, and "0 prompts" would read as a quiet day, not a gap.
    if (today && provider && provider.hasPromptStats !== false)
      text += " · " + Number(provider.todayPrompts || 0) + " prompts · "
        + Number(provider.todaySessions || 0) + " sessions"
    return text
  }

  function weekPeak(p) {
    var days = p ? (p.recentDays || []) : []
    var peak = 0
    for (var i = 0; i < days.length; i++) peak = Math.max(peak, Number(days[i].messageCount || 0))
    return peak
  }

  function modelRows(p) {
    var usageByModel = p ? (p.modelUsage || {}) : {}
    var rows = []
    for (var id in usageByModel) {
      var bucket = usageByModel[id] || {}
      var input = Number(bucket.inputTokens || 0)
      var output = Number(bucket.outputTokens || 0)
      var cacheRead = Number(bucket.cacheReadInputTokens || 0)
      var cacheWrite = Number(bucket.cacheCreationInputTokens || 0)
      rows.push({
        name: usage.friendlyModelName(id),
        total: input + output + cacheRead + cacheWrite,
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite
      })
    }
    rows.sort(function(a, b) { return b.total - a.total })
    return rows.slice(0, 4)
  }

  function modelTooltip(row) {
    if (!row) return ""
    return "In " + usage.formatTokenCount(row.input)
      + " · out " + usage.formatTokenCount(row.output)
      + " · cache read " + usage.formatTokenCount(row.cacheRead)
      + " · cache write " + usage.formatTokenCount(row.cacheWrite)
  }

  // Only speaks up when the numbers cover more than this machine.
  function footerText() {
    if (usage.syncStatusText !== "") return usage.syncStatusText
    if (provider && provider.syncEnabled && provider.syncDeviceCount > 0)
      return "Merged from " + provider.syncDeviceCount + " device" + (provider.syncDeviceCount === 1 ? "" : "s")
    return ""
  }

  // Agents that ship a white mark carry an `assets/<id>-light.svg` twin for
  // light surfaces; marks that work on both (Claude's brand-orange) ship one
  // file. The luminance check decides which candidate to try first.
  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  // Marks resolve by convention, so a new agent's data file needs nothing
  // from this panel: assets/<id>.svg if it ships one, the module's bar glyph
  // if it doesn't.
  function iconCandidatesForProvider(p, surfaceColor) {
    if (!p) return []
    var candidates = []
    if (colorLuminance(surfaceColor || Commons.Color.background) >= 0.5)
      candidates.push(Qt.resolvedUrl("assets/" + p.providerId + "-light.svg"))
    candidates.push(Qt.resolvedUrl("assets/" + p.providerId + ".svg"))
    return candidates
  }

  // Nothing to report, nothing in the bar: Bar.qml collapses a slot whose item
  // is invisible, so the icon appears the moment the first scan finds usage and
  // stays away entirely on a machine that has never run either CLI.
  visible: providers.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onProviderIndexChanged: if (panelFlick) panelFlick.contentY = 0
  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    usage.refreshLimits()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Main {
    id: usage
    settings: root.settings
  }

  // Cheap enough to keep running: it only re-evaluates text bindings, and a
  // stale "resets in 2h" on a panel that is open is worse than a timer.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function next(): string { root.selectProvider(root.providerIndex + 1); return "ok" }
  }

  // ---------------------------------------------------------------- glance
  //
  // The bar button shows Claude's session and weekly meters inline, whichever
  // provider the panel has selected. Without Claude limits (signed out, no
  // record yet) or on a vertical bar it falls back to the plain glyph.

  readonly property var claudeProvider: {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].providerId === "claude") return providers[i]
    return null
  }
  readonly property var claudeLimits: limitWindows(claudeProvider)

  function glanceWindow(title) {
    for (var i = 0; i < claudeLimits.length; i++)
      if (claudeLimits[i].title === title) return claudeLimits[i]
    return null
  }

  readonly property var sessionWindow: glanceWindow("Session")
  readonly property var weeklyWindow: glanceWindow("Weekly")
  readonly property bool showGlance: !button.vertical && (!!sessionWindow || !!weeklyWindow)

  // Two remembered switches in the budget section (middle click flips the
  // first): the pill shows what is left today as one battery instead of the
  // 5h/week split, and that battery reads either the actual weekly percent
  // left or today's budget scaled to 100.
  readonly property string viewPath: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/agents/view.json"
  property bool batteryView: false
  property bool batteryScaled: false

  FileView {
    id: viewFile
    path: root.viewPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        root.batteryView = !!parsed.battery
        root.batteryScaled = !!parsed.scaled
      } catch (e) {}
    }
  }

  function setView(battery, scaled) {
    batteryView = battery
    batteryScaled = scaled
    viewFile.setText(JSON.stringify({ battery: battery, scaled: scaled }, null, 2) + "\n")
  }

  readonly property bool showBattery: batteryView && !!budgetToday
  readonly property bool batteryOver: !!budgetToday && budgetToday.over
  readonly property real batteryLeft: budgetToday ? budgetToday.cap - budgetToday.total : 0
  readonly property real batteryFraction: budgetToday && budgetToday.budget > 0
    ? clamp(batteryLeft / budgetToday.budget, 0, 1) : 0
  readonly property string batteryText: !budgetToday ? ""
    : batteryOver ? budgetPercent(-batteryLeft)
    : batteryScaled ? String(Math.round(batteryFraction * 100))
    : budgetPercent(batteryLeft)

  // The battery's 5h strip: a line along the bottom filled to the session
  // percent, with a tick at how far through the 5 hours the clock is. Fill
  // past the tick means the session is going faster than it lasts.
  readonly property real sessionSpanMs: 5 * 3600 * 1000
  readonly property bool showSessionStrip: showBattery && !!sessionWindow && sessionWindow.resetAt !== ""
  readonly property real sessionElapsed: {
    var ms = resetMsFor(sessionWindow)
    return ms > 0 ? clamp(1 - ms / sessionSpanMs, 0, 1) : 0
  }

  // Chevrons on the strip: how fast the 5h percent rose over the last 15
  // minutes, against the rate that would land exactly on 100% at the reset.
  // Pointing right when faster (red at twice it, yellow from 1.4x), left when
  // slower, none within 0.8-1.1x. Samples live in memory only; a drop in the
  // percent is a new window and starts over.
  property var sessionSamples: []
  readonly property real burnSpanMs: 15 * 60 * 1000

  onSessionWindowChanged: {
    var w = sessionWindow
    if (!w || w.resetAt === "") { sessionSamples = []; return }
    var list = sessionSamples
    var last = list.length > 0 ? list[list.length - 1] : null
    if (last && w.percent < last.p) list = []
    else if (last && w.percent === last.p && nowMs - last.t < 20000) return
    list = list.filter(function(s) { return nowMs - s.t <= burnSpanMs })
    list.push({ t: nowMs, p: w.percent })
    sessionSamples = list
  }

  readonly property int burnLevel: {
    var list = sessionSamples
    if (list.length < 2) return 0
    var first = list[0], last = list[list.length - 1]
    // Under five minutes of history one whole-percent step reads as a sprint.
    if (last.t - first.t < 5 * 60 * 1000) return 0
    var rate = Math.max(0, last.p - first.p) / (last.t - first.t)
    var left = resetMsFor(sessionWindow)
    if (left <= 0 || last.p >= 1) return rate > 0 ? 3 : 0
    var ratio = rate / ((1 - last.p) / left)
    return ratio >= 2 ? 3 : ratio >= 1.4 ? 2 : ratio >= 1.1 ? 1
      : ratio >= 0.8 ? 0 : ratio >= 0.5 ? -1 : ratio >= 0.2 ? -2 : -3
  }
  // The strip takes whichever is louder: the burn rate or the 5h limit level.
  readonly property int stripLevel: Math.max(limitLevel(sessionWindow), burnLevel >= 3 ? 2 : burnLevel === 2 ? 1 : 0)
  readonly property color stripColor: stripLevel === 2 ? urgent : stripLevel === 1 ? warning : button.foreground

  // A window that resets while nothing refreshes should read 0%, not its
  // stale figure, so the clock ticks whenever the bar shows meters.
  Timer {
    interval: 30000
    running: root.showGlance && !root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱚣"
    labelVisible: !root.showGlance
    fontSize: Style.bar.iconFont
    fixedWidth: root.showGlance ? pill.width + Style.space(10) : (vertical ? -1 : Style.bar.iconSlot)
    fixedHeight: vertical ? Style.bar.iconSlot : -1
    active: root.alarming
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.launchAgent()
      else if (buttonCode === Qt.MiddleButton) root.setView(!root.batteryView, root.batteryScaled)
      else root.toggle()
    }

    // One pill split in two: 5h on top, week below. Each half is a fill with
    // its label on the left and percentage on the right, both inverted where
    // the fill covers them. The 5h label is the time to reset.
    Item {
      id: pill
      visible: root.showGlance
      anchors.centerIn: parent
      width: Style.space(112)
      height: root.pillHalfHeight * 2 + pillDivider.height
      layer.enabled: true
      layer.effect: MultiEffect {
        maskEnabled: true
        maskSource: pillMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
      }

      Column {
        anchors.fill: parent
        visible: !root.showBattery

        PillHalf {
          window: root.sessionWindow
          label: { var ms = root.resetMsFor(root.sessionWindow); return ms > 0 ? root.formatDuration(ms) : "5h" }
        }
        Rectangle {
          id: pillDivider
          width: pill.width
          height: 1
          color: root.barBackground
        }
        PillHalf { window: root.weeklyWindow; label: "week" }
      }

      // The battery: full at the start of the day, emptying from the left
      // like a phone battery, with the number in the middle. The 5h strip
      // takes the bottom edge when a session is running.
      Item {
        id: battery
        width: parent.width
        height: parent.height - (root.showSessionStrip ? sessionStrip.height + 1 : 0)
        visible: root.showBattery
        readonly property string label: root.batteryOver ? "over " + root.batteryText : root.batteryText

        Rectangle {
          anchors.fill: parent
          color: root.track
        }

        BatteryText { color: root.batteryOver ? root.urgent : button.foreground }

        Item {
          id: batteryFill
          height: parent.height
          width: parent.width * root.batteryFraction
          x: parent.width - width
          clip: true

          Behavior on width {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
          }

          // Drawn at the pill's own origin so the inverted text lines up.
          Item {
            x: -batteryFill.x
            width: battery.width
            height: battery.height

            Rectangle {
              anchors.fill: parent
              color: button.foreground
            }

            BatteryText { color: root.barBackground }
          }
        }
      }

      Rectangle {
        id: sessionStrip
        visible: root.showSessionStrip
        anchors.bottom: parent.bottom
        width: parent.width
        height: Style.space(6)
        color: root.track

        // The fill ends in a point for faster than it lasts, a notch for
        // slower, flat on pace, with the chevrons cut out behind the end,
        // parallel to it. The end alone merges into the track, so it does
        // not count as one. A short fill is drawn
        // long enough to hold them, clear of the rounded left end.
        Canvas {
          id: sessionFill
          anchors.fill: parent
          readonly property int count: Math.abs(root.burnLevel)
          readonly property real depth: height * 0.45
          readonly property real step: height * 0.8
          property real head: width * root.clamp(root.sessionWindow ? root.sessionWindow.percent : 0, 0, 1)

          Behavior on head {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
          }

          onHeadChanged: requestPaint()
          onWidthChanged: requestPaint()
          Connections {
            target: root
            function onBurnLevelChanged() { sessionFill.requestPaint() }
            function onStripColorChanged() { sessionFill.requestPaint() }
            function onBarBackgroundChanged() { sessionFill.requestPaint() }
          }

          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var h = height, half = h / 2, d = depth
            var dir = root.burnLevel > 0 ? 1 : root.burnLevel < 0 ? -1 : 0
            var end = dir === 0 ? sessionFill.head : Math.max(sessionFill.head, Style.space(7) + d + count * step)
            if (end <= 0) return

            ctx.fillStyle = root.stripColor
            ctx.beginPath()
            ctx.moveTo(0, 0)
            if (dir > 0) { ctx.lineTo(end - d, 0); ctx.lineTo(end, half); ctx.lineTo(end - d, h) }
            else if (dir < 0) { ctx.lineTo(end, 0); ctx.lineTo(end - d, half); ctx.lineTo(end, h) }
            else { ctx.lineTo(end, 0); ctx.lineTo(end, h) }
            ctx.lineTo(0, h)
            ctx.closePath()
            ctx.fill()

            ctx.strokeStyle = root.barBackground
            ctx.lineWidth = 1.5
            for (var i = 1; i <= count; i++) {
              var o = end - i * step
              ctx.beginPath()
              if (dir > 0) { ctx.moveTo(o - d, 0); ctx.lineTo(o, half); ctx.lineTo(o - d, h) }
              else { ctx.moveTo(o, 0); ctx.lineTo(o - d, half); ctx.lineTo(o, h) }
              ctx.stroke()
            }
          }
        }

        // Only on pace: the chevrons already say which side of it you are.
        Rectangle {
          visible: root.burnLevel === 0
          x: Math.round(parent.width * root.sessionElapsed) - 1
          width: 2
          height: parent.height
          color: root.barBackground
        }
      }

      Rectangle {
        id: pillMask
        anchors.fill: parent
        radius: height / 2
        visible: false
        layer.enabled: true
      }
    }
  }

  readonly property int pillHalfHeight: Style.space(9)
  readonly property int pillPadding: Style.space(9)

  // Half of the glance pill: track, fill, and the text drawn twice, the
  // second copy in the bar background and clipped to the fill.
  component PillHalf: Item {
    id: half
    property var window: null
    property string label: ""
    readonly property real percent: window ? window.percent : 0
    readonly property string percentText: window ? Math.round(window.percent * 100) + "%" : ""

    width: pill.width
    height: root.pillHalfHeight

    Rectangle {
      anchors.fill: parent
      color: root.track
    }

    PillText { text: half.label; color: button.foreground }
    PillText { text: half.percentText; color: button.foreground; alignRight: true }

    Item {
      height: parent.height
      width: parent.width * root.clamp(half.percent, 0, 1)
      clip: true

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }

      Rectangle {
        width: half.width
        height: half.height
        color: root.limitColor(half.window, button.foreground)
      }

      PillText { text: half.label; color: root.barBackground }
      PillText { text: half.percentText; color: root.barBackground; alignRight: true }
    }
  }

  component BatteryText: Text {
    textFormat: Text.PlainText
    text: battery.label
    anchors.centerIn: parent
    font.family: root.fontFamily
    font.pixelSize: Style.font.heading
    font.bold: true
  }

  component PillText: Text {
    property bool alignRight: false
    textFormat: Text.PlainText
    x: alignRight ? pill.width - root.pillPadding - implicitWidth : root.pillPadding
    height: root.pillHalfHeight
    verticalAlignment: Text.AlignVCenter
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption - 1
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // Taller than the control panels on purpose: this one is a dashboard, and
    // the whole point is reading limits and history without scrolling.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(900))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          root.selectProvider(root.providerIndex + dx)
        }
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refreshNow() }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(8)

          // ---------- Hero: provider mark · name · plan ----------
          PanelHero {
            id: hero
            visible: !!root.provider
            width: parent.width
            title: root.provider ? root.provider.providerName : ""
            meta: root.heroMeta(root.provider)
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Item {
                id: heroMark
                property var candidates: root.iconCandidatesForProvider(root.provider, root.surface)
                // Provider objects are rebuilt on every refresh, which churns the
                // array's identity without changing its content. Restart the fallback
                // walk only when the URLs change: re-pointing source at a URL whose
                // load already failed emits no statusChanged, so an identity-only
                // reset would strand the walker on a missing -light twin.
                property string candidatesKey: candidates.join("\n")
                property int candidateIndex: 0
                onCandidatesKeyChanged: candidateIndex = 0

                width: Style.font.display
                height: Style.font.display

                Image {
                  id: heroMarkImage
                  anchors.fill: parent
                  source: heroMark.candidateIndex < heroMark.candidates.length ? heroMark.candidates[heroMark.candidateIndex] : ""
                  sourceSize.width: Style.font.display * 2
                  sourceSize.height: Style.font.display * 2
                  fillMode: Image.PreserveAspectFit
                  // Advancing source from inside its own status change trips the
                  // binding-loop detector; defer the step one tick.
                  onStatusChanged: if (status === Image.Error && heroMark.candidateIndex < heroMark.candidates.length)
                    Qt.callLater(function() { heroMark.candidateIndex++ })
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  visible: heroMarkImage.status !== Image.Ready
                  text: button.text
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }
          }

          Text {
            visible: root.providers.length === 0
            width: parent.width
            topPadding: Style.space(24)
            text: "No AI coding subscriptions found.\nAgents show up here once you've used them."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---------- Provider switch ----------
          Row {
            id: providerSwitch
            visible: root.providers.length > 1
            width: parent.width
            spacing: Style.spacing.md

            readonly property real cellWidth: root.providers.length > 0
              ? (width - spacing * (root.providers.length - 1)) / root.providers.length
              : 0

            Repeater {
              model: root.providers

              Button {
                required property var modelData
                required property int index

                width: providerSwitch.cellWidth
                text: modelData.providerName
                selected: index === root.providerIndex
                hasCursor: root.cursorActive && index === root.providerIndex
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: {
                  root.cursorActive = true
                  root.selectProvider(index)
                }
                onHovered: function(isHovered) { if (isHovered) root.cursorActive = true }
              }
            }
          }

          // ---------- Status ----------
          BorderSurface {
            visible: !!root.provider && String(root.provider.usageStatusText || "") !== ""
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: statusText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.provider ? String(root.provider.authHelpText || "") : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Daily budget ----------
          PanelSeparator {
            visible: budgetSection.visible
            foreground: root.foreground
          }

          Column {
            id: budgetSection
            visible: !!root.provider && root.provider.providerId === "claude" && !!root.budgetToday
            width: parent.width
            spacing: Style.space(4)

            readonly property var today: root.budgetToday
            readonly property bool over: !!today && today.over

            PanelSectionHeader {
              width: parent.width
              text: "DAILY BUDGET"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // What is left for today leads; the running totals sit beside it.
            Item {
              width: parent.width
              implicitHeight: budgetLeft.implicitHeight

              Text {
                id: budgetLeft
                textFormat: Text.PlainText
                text: !budgetSection.today ? ""
                  : root.budgetPercent(Math.abs(budgetSection.today.cap - budgetSection.today.total))
                color: budgetSection.over ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                font.bold: true
                anchors.left: parent.left
              }

              Text {
                textFormat: Text.PlainText
                text: budgetSection.over ? "over budget" : "left today"
                color: budgetSection.over ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.left: budgetLeft.right
                anchors.leftMargin: Style.space(6)
                anchors.baseline: budgetLeft.baseline
              }

              Text {
                textFormat: Text.PlainText
                text: budgetSection.today
                  ? root.budgetPercent(budgetSection.today.total) + " of " + root.budgetPercent(budgetSection.today.cap) + " used"
                  : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.baseline: budgetLeft.baseline
              }
            }

            Meter {
              width: parent.width
              value: budgetSection.today ? budgetSection.today.total / budgetSection.today.cap : -1
              fillColor: budgetSection.over ? root.urgent : root.foreground
            }

            Item { width: 1; height: Style.space(2) }

            BudgetGraph {
              width: parent.width
              days: root.budgetDays
            }

            Item { width: 1; height: Style.space(2) }

            Toggle {
              width: parent.width
              label: "Left today in the bar"
              description: "One battery pill instead of 5h and week. Activate on middle click."
              checked: root.batteryView
              foreground: root.foreground
              fontFamily: root.fontFamily
              rounded: false
              onClicked: root.setView(!root.batteryView, root.batteryScaled)
            }

            Toggle {
              width: parent.width
              label: "Count today from 100"
              // Only means something with the battery on.
              enabled: root.batteryView
              opacity: enabled ? 1 : 0.4
              description: "Off shows the actual percent left. On counts today down from 100 to 0."
              checked: root.batteryScaled
              foreground: root.foreground
              fontFamily: root.fontFamily
              rounded: false
              onClicked: root.setView(root.batteryView, !root.batteryScaled)
            }
          }

          // ---------- Balance / limits ----------
          PanelSeparator {
            visible: balanceSection.visible || limitsSection.visible
            foreground: root.foreground
          }

          Column {
            id: balanceSection
            visible: !!root.balance
            width: parent.width
            spacing: Style.space(10)

            // The meter shows what is left, not what is used: a prepaid
            // account drains toward empty rather than filling toward a cap.
            readonly property real ratio: root.balance && root.balance.funded > 0
              ? root.clamp(root.balance.remaining / root.balance.funded, 0, 1)
              : -1

            PanelSectionHeader {
              width: parent.width
              text: "BALANCE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(balanceLabel.implicitHeight, balanceValue.implicitHeight)

              Text {
                id: balanceLabel
                text: "Prepaid credits"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: balanceValue
                textFormat: Text.PlainText
                text: root.balance ? root.formatMoney(root.balance.remaining, root.balance.currency) : ""
                color: root.balanceAlarming ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Meter {
              visible: balanceSection.ratio >= 0
              width: parent.width
              value: balanceSection.ratio
              alarming: root.balanceAlarming
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.balanceDetailText(root.balance)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Column {
            id: limitsSection
            visible: root.limits.length > 0
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "LIMITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.limits

              LimitRow {
                required property var modelData
                width: limitsSection.width
                window: modelData
              }
            }
          }

          // ---------- Usage ----------
          PanelSeparator {
            visible: usageSection.visible
            foreground: root.foreground
          }

          Column {
            id: usageSection
            visible: !!root.provider && root.provider.recentDays && root.provider.recentDays.length > 0
            width: parent.width
            spacing: Style.space(4)

            readonly property var days: root.provider ? (root.provider.recentDays || []) : []
            readonly property real peak: Math.max(1, root.weekPeak(root.provider))

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY DAY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: usageSection.days

              DayRow {
                required property var modelData
                required property int index

                width: usageSection.width
                day: modelData
                ratio: Number(modelData.messageCount || 0) / usageSection.peak
                // By date, not by position: the Claude stats-cache fallback can
                // hand us a window that stops short of today.
                today: String(modelData.date || "") === root.todayDate()
              }
            }
          }

          // ---------- Models ----------
          PanelSeparator {
            visible: modelSection.visible
            foreground: root.foreground
          }

          Column {
            id: modelSection
            visible: root.models.length > 0
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY MODEL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.models

              ModelRow {
                required property var modelData
                width: modelSection.width
                row: modelData
                // Scaled to the heaviest model, so the top row is always full —
                // the same scale-to-peak the weekly chart uses for its busiest day.
                share: modelData.total / Math.max(1, root.models[0].total)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: root.footerText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // A limit window: label and percentage, meter, and reset countdown.
  component LimitRow: Column {
    id: limitRow
    property var window: null

    readonly property color levelColor: root.limitColor(window, root.foreground)

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        textFormat: Text.PlainText
        // A model-scoped window is titled after its model, and those names run
        // long enough to reach the percentage, so the title gives way first.
        text: limitRow.window ? limitRow.window.title : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: limitValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitValue
        textFormat: Text.PlainText
        text: limitRow.window && limitRow.window.percent >= 0
          ? Math.round(limitRow.window.percent * 100) + "%"
          : "—"
        color: limitRow.levelColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: limitRow.window ? limitRow.window.percent : -1
      fillColor: limitRow.levelColor
    }

    Text {
      id: resetText
      textFormat: Text.PlainText
      width: parent.width
      text: {
        var remainingMs = root.resetMsFor(limitRow.window)
        return remainingMs > 0 ? "Resets in " + root.formatDuration(remainingMs) : ""
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Rounded track showing the percentage of the allowance used.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property color fillColor: alarming ? root.urgent : root.foreground
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.fillColor

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

  }

  // One column per day of the weekly window: what was used, with a tick at
  // what the day had available (its seventh plus anything carried in). Days
  // still ahead show what they get if every day before ends on budget.
  component BudgetGraph: Column {
    id: graph
    property var days: []
    readonly property real gap: Style.space(4)
    readonly property real columnWidth: (width - gap * Math.max(0, days.length - 1)) / Math.max(1, days.length)
    readonly property real peak: {
      var m = 0.01
      for (var i = 0; i < days.length; i++) m = Math.max(m, days[i].used, days[i].budget)
      return m * 1.1
    }

    spacing: Style.space(2)

    Row {
      spacing: graph.gap

      Repeater {
        model: graph.days

        Item {
          required property var modelData
          width: graph.columnWidth
          height: Style.space(34)

          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: root.track
          }

          Rectangle {
            visible: modelData.used > 0
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width * 0.6
            height: Math.max(1, parent.height * modelData.used / graph.peak)
            radius: Style.space(2)
            color: modelData.over ? root.urgent
              : modelData.today ? root.foreground : root.alpha(root.foreground, 0.55)
          }

          Rectangle {
            visible: modelData.budget > 0
            y: Math.round(parent.height * (1 - modelData.budget / graph.peak))
            width: parent.width
            height: 1
            color: modelData.future ? root.alpha(root.dim, 0.5) : root.dim
          }
        }
      }
    }

    Row {
      spacing: graph.gap

      Repeater {
        model: graph.days

        Text {
          required property var modelData
          width: graph.columnWidth
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: modelData.label
          color: modelData.today ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: modelData.today
        }
      }
    }

    Row {
      spacing: graph.gap

      Repeater {
        model: graph.days

        Text {
          required property var modelData
          width: graph.columnWidth
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: modelData.used >= 0 ? String(Math.round(modelData.used * 100)) : "·"
          color: modelData.today ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // One row per day: label, bar, tokens. Today is picked out in full
  // foreground so the week reads as a run-up to right now.
  component DayRow: Item {
    id: dayRow
    property var day: null
    property real ratio: 0
    property bool today: false

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.space(2)

    Text {
      id: dayLabel
      textFormat: Text.PlainText
      text: root.dayLabel(dayRow.day ? dayRow.day.date : "", dayRow.today)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)
        color: dayRow.today ? root.foreground : root.alpha(root.foreground, 0.55)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: dayValue
      textFormat: Text.PlainText
      text: usage.formatTokenCount(dayRow.day ? Number(dayRow.day.messageCount || 0) : 0)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayRow.day, dayRow.today)
      fontFamily: root.fontFamily
    }
  }

  // Model rows read as a table: the share bar fills the row behind the label
  // instead of stacking under it, which keeps the whole dashboard on one screen.
  component ModelRow: Item {
    id: modelRow
    property var row: null
    property real share: 0

    implicitHeight: modelName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.14)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: modelName
      textFormat: Text.PlainText
      text: modelRow.row ? modelRow.row.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: modelTokens.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelTokens
      textFormat: Text.PlainText
      text: modelRow.row ? usage.formatTokenCount(modelRow.row.total) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: modelHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: modelHover.containsMouse
      text: root.modelTooltip(modelRow.row)
      fontFamily: root.fontFamily
    }
  }
}

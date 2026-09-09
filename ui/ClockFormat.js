.pragma library

// Dates follow the Omarchy clock: the bar's `omarchy.clock` entry in
// shell.json holds a Qt format such as "yyyy-MM-dd HH:mm". Payment rows
// show the date part of that format without the year; detail pages add
// the time part back.

var defaultFormat = "dddd HH:mm"
var defaultAltFormat = "d MMMM 'W'ww yyyy"

// Locate the clock entry wherever it sits in the bar layout.
function clockSettings(shellJson) {
    var layout = shellJson && shellJson.bar && shellJson.bar.layout ? shellJson.bar.layout : {}
    var lists = ["left", "center", "right"]
    for (var i = 0; i < lists.length; i++) {
        var entries = layout[lists[i]] || []
        for (var j = 0; j < entries.length; j++) {
            if (entries[j] && entries[j].id === "omarchy.clock") return entries[j]
        }
    }
    return {}
}

// Split a Qt date/time format into quoted literals, letter tokens, and separators.
function tokenize(format) {
    var out = [], i = 0
    format = String(format || "")
    while (i < format.length) {
        var c = format[i], j = i
        if (c === "'") {
            j = format.indexOf("'", i + 1)
            if (j < 0) j = format.length - 1
            out.push({literal: format.slice(i, j + 1)})
            i = j + 1
        } else if (/[A-Za-z]/.test(c)) {
            if (format.slice(i, i + 2) === "AP" || format.slice(i, i + 2) === "ap") j = i + 2
            else while (j < format.length && format[j] === c) j++
            out.push({token: format.slice(i, j)})
            i = j
        } else {
            while (j < format.length && !/[A-Za-z']/.test(format[j])) j++
            out.push({separator: format.slice(i, j)})
            i = j
        }
    }
    return out
}

// Keep the tokens `wanted` accepts. Separators survive between two kept
// neighbors; where a token was removed between them, a single space remains.
function keep(format, wanted) {
    var result = "", pending = "", dropped = false, started = false
    tokenize(format).forEach(function (piece) {
        if (piece.separator !== undefined) { pending += piece.separator; return }
        if (piece.literal !== undefined || !wanted.test(piece.token)) { dropped = true; return }
        if (started) result += dropped ? " " : pending
        result += piece.token
        pending = ""
        dropped = false
        started = true
    })
    return result
}

function hasDay(format) { return /(^|[^d])d{1,2}([^d]|$)/.test(format) }
function hasMonth(format) { return /M/.test(format) }

// The configured format without its year or time, e.g. "yyyy-MM-dd HH:mm" → "MM-dd".
// A weekday-only clock such as "dddd HH:mm" falls back to the alternate format.
function dateFormat(format, altFormat) {
    var candidates = [format, altFormat, defaultAltFormat]
    for (var i = 0; i < candidates.length; i++) {
        var candidate = keep(candidates[i] || "", /^(d+|M+)$/)
        if (hasDay(candidate) && hasMonth(candidate)) return candidate
    }
    return "d MMMM"
}

// The time part of the configured format, e.g. "yyyy-MM-dd HH:mm" → "HH:mm".
function timeFormat(format) {
    var candidate = keep(format || "", /^(H+|h+|m+|s+|z+|A|AP|a|ap|t)$/)
    return /[Hh]/.test(candidate) ? candidate : "HH:mm"
}

function isoWeek(date) {
    var day = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()))
    day.setUTCDate(day.getUTCDate() + 4 - (day.getUTCDay() || 7))
    var week = Math.ceil(((day - Date.UTC(day.getUTCFullYear(), 0, 1)) / 86400000 + 1) / 7)
    return (week < 10 ? "0" : "") + week
}

function format(date, qtFormat) {
    return Qt.formatDateTime(date, String(qtFormat).replace(/ww/g, isoWeek(date)))
}

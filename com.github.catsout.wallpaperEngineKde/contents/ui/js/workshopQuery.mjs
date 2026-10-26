// Steam Workshop query + parse helpers for Wallpaper Engine (appid 431960)
// No API key needed: uses the public community browse page.

export const WORKSHOP_APPID = "431960";

export const SortMode = Object.freeze({
    Trend: "trend",
    TopRated: "toprated",
    MostSubscribed: "mostsubscribed",
    Newest: "newest"
});

// Steam browse page: one screenful per p=<page>. Each page holds ~30 items.
export function buildBrowseUrl({ query = "", sort = SortMode.Trend, page = 1, requiredTags = [] } = {}) {
    const params = [
        "appid=" + WORKSHOP_APPID,
        "searchtext=" + encodeURIComponent(query),
        "browsesort=" + sort,
        "section=readytouseitems",
        "actualsort=" + sort,
        "p=" + page
    ];
    for (const tag of requiredTags) {
        params.push("requiredtags[]=" + encodeURIComponent(tag));
    }
    return "https://steamcommunity.com/workshop/browse/?" + params.join("&");
}

export function workshopUrl(id) {
    return "https://steamcommunity.com/sharedfiles/filedetails/?id=" + id;
}

export function decodeEntities(str) {
    if (!str) return "";
    return str
        .replace(/&amp;/g, "&")
        .replace(/&lt;/g, "<")
        .replace(/&gt;/g, ">")
        .replace(/&quot;/g, "\"")
        .replace(/&#39;/g, "'")
        .replace(/&#x([0-9a-fA-F]+);/g, (m, h) => String.fromCodePoint(parseInt(h, 16)))
        .replace(/&#(\d+);/g, (m, d) => String.fromCodePoint(parseInt(d, 10)));
}

// Steam's SSR page embeds the full per-item JSON in an escaped string
// (e.g. "results":[{"publishedfileid":"…","tags":[…]}]). It carries the
// authoritative data — including the age-rating tags (""Mature"",
// ""Questionable"") that the author-declared project.json often lacks.
// Return a map id -> { tags: [] } so callers can re-flag items.
export function extractFeedTags(html) {
    const out = {};
    if (!html) return out;
    // Find the escaped results array and progressively unescape backslashes.
    let i = html.indexOf('results\\\\\\":[{\\\\\\"publishedfileid');
    if (i < 0) i = html.indexOf('"results":[{\\"publishedfileid');
    if (i < 0) i = html.indexOf('"results":[{"publishedfileid');
    if (i < 0) return out;
    // keep only the array, then flatten one layer of ``\"`` escaping.
    let blob = html.substring(i, html.length);
    let prev = null;
    while (prev !== blob) {
        prev = blob;
        blob = blob.replace(/\\\\\\"/g, '"');
    }
    blob = blob.replace(/\\\\"/g, '"');
    // Now walk brace-by-brace and read entries atomically. Each entry starts
    // with {"publishedfileid" and ends where the next one begins (the last
    // entry ends at the array's ]). Note: ","{" also occurs between tags, so
    // we must anchor on the next entry's exact key, not on any "},{".
    let pos = 0;
    while (true) {
        const open = blob.indexOf('{"publishedfileid":"', pos);
        if (open < 0) break;
        const close = blob.indexOf(',{"publishedfileid":"', open);
        const cut = close < 0 ? blob.indexOf(']', open) : close;
        if (cut < 0) break;
        const entry = blob.substring(open, cut + 1);
        const id = /"publishedfileid":"(\d+)"/.exec(entry);
        const tags = [];
        {
            // String.prototype.matchAll is missing in this QML/JS engine;
            // use a classic exec loop instead.
            const re = /"tag":"([^"]+)"/g;
            let m;
            while ((m = re.exec(entry)) !== null) tags.push(m[1]);
        }
        if (id) out[id[1]] = { tags: tags };
        pos = cut + 1;
    }
    return out;
}

// Parse the Steam community browse page. Returns items:
// { id, title, author, rating (0-5), preview (image url), tags: [...] }
export function parseBrowseHtml(html, feedTags) {
    if (!html) return [];
    const feed = feedTags || extractFeedTags(html);
    const items = [];
    const byId = {};
    const anchorRe = /<a href="https:\/\/steamcommunity\.com\/sharedfiles\/filedetails\/\?id=(\d+)"[^>]*>/g;
    const starsRe = /SVGIcon_Star_Filled/g;

    const anchors = [];
    let m;
    while ((m = anchorRe.exec(html)) !== null) {
        anchors.push({ id: m[1], pos: m.index });
    }
    // Merge each card: an item appears twice (image anchor + title anchor).
    // Use the span from the image anchor up to the next card's image anchor.
    for (let k = 0; k < anchors.length; k++) {
        const cur = anchors[k];
        if (byId[cur.id] !== undefined) continue;
        // find span end: next anchor with a different id
        let next = k + 1;
        while (next < anchors.length && anchors[next].id === cur.id) next++;
        const end = next < anchors.length ? anchors[next].pos : html.length;
        const seg = html.substring(cur.pos, end);

        const img = /<img src="([^"]+)"[^>]*alt="([^"]*)"/.exec(seg);
        if (!img) continue;

        let title = img[2];
        if (!title) {
            const lt = /<a href="https:\/\/steamcommunity\.com\/sharedfiles\/filedetails\/\?id=(\d+)"[^>]*>[^<]*?([^<]+)<\/a>/.exec(seg);
            if (lt) title = lt[2].trim();
        }
        const author = />By\s*([^<]+)</.exec(seg);
        const rating = Math.min((seg.match(starsRe) || []).length, 5);
        const item = {
            id: cur.id,
            title: decodeEntities(title).trim(),
            author: author ? author[1].trim() : "",
            rating: rating,
            preview: img[1].replace(/&amp;/g, "&"),
            tags: (feed[cur.id] && feed[cur.id].tags) || []
        };
        byId[cur.id] = item;
        items.push(item);
        k = next - 1;
    }
    return items;
}

// Build the browse URL for a specific search
export function isInstalledTooltip(installed) {
    return installed ? "This wallpaper is already installed" : "This wallpaper is not installed yet";
}
export function parseTotalPages(html) {
    if (!html) return 1;
    const re = /class="pagelink"[^>]*>([0-9,\.]+)<\/a>/g;
    let maxP = 1;
    let m;
    while ((m = re.exec(html)) !== null) {
        const n = parseInt(String(m[1]).replace(/[,\.]/g, ""), 10);
        if (!isNaN(n) && n > maxP) maxP = n;
    }
    return Math.min(maxP, 1000);
}

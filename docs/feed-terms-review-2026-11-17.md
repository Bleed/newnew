# Feed terms review — 17 Nov 2026

What the publishers behind newnew's feeds say about using their RSS feeds and site content.
Fact-finding from their published terms, read on the web on 2026-11-17. **Not legal advice.**
Take it to an IP lawyer before charging for the app.

## The short version

- **Almost every general news outlet limits its feeds to personal or non-commercial use.**
  Some say so in RSS terms of their own: BBC, NPR, Fox News, Fortune, CNA and WNYC. Others
  apply their site terms: Guardian, Al Jazeera, France 24, Euronews, NYT, SCMP, The Local
  and Condé Nast. A free reader app sits in a grey area. **A paid app (trial, then a one-time
  purchase) is what most clearly runs into these clauses.**
- **Some outlets have pursued apps before.**
  - NYT called the Pulse reader commercial use of its feeds (2010).
  - CBC threatened podcast-app makers (2016).
- **Pictures are the second issue.** BBC, ScienceDaily, Fortune, Future plc, Artnet and The Art
  Newspaper exclude pictures, or forbid showing them apart from their text. Fashion and
  design titles mostly run agency or photographers' pictures.
- **A few outlets say "do not modify" the feed:** Fox, ESPN, ScienceDaily, Yahoo and TechCrunch.
  Cutting a description to 150 characters may count as modifying it.
- **Some outlets reserve AI use beyond training.** The Guardian (combining with other data),
  France 24, Al Jazeera, NYT, SCMP, Skift and The Points Guy reserve AI / text-and-data-mining
  uses. The on-device read is arguably none of these, but it is the closest fit.
- **YouTube's robots.txt disallows `/feeds/videos.xml`,** the feed newnew reads channels from.
  Each iPhone fetching its reader's own channels is easier to defend than a server would be,
  but no permission is written down.
- **Explicitly fine:**
  - Medical Xpress (feeds free for commercial use).
  - NASA (public domain).
  - Our World in Data (CC BY).
  - TechCrunch and Yahoo/Engadget (RSS licences that match a reader: unmodified, credited,
    linked, no ads).
  - ABC News (feed page names aggregators).
  - ESPN (display in apps allowed, unmodified).
  - Podcasts in general (open feeds are meant for any podcast app).

## Ratings by outlet

**High** (explicit non-commercial, anti-aggregation, or a history of enforcing):

| Outlet | Why |
| --- | --- |
| BBC News, BBC Sport, BBC podcast | Business use of RSS needs a licence; pictures excluded; AI use needs permission |
| The Guardian, Today in Focus | Personal, non-commercial only; no combining with other data through AI without approval |
| NPR, Up First | Feeds only for personal use or non-commercial nonprofits |
| Al Jazeera | Non-commercial; no showing their links inside a third-party app |
| France 24 | Personal and private use; deep links need authorisation; AI opt-out file |
| CBC News | Commercial RSS use by request; threatened apps in 2016 |
| New York Times, The Daily, Hard Fork | Feeds part of the services: personal, non-commercial; AI reserved; history with Pulse |
| Fox News | RSS terms: personal, non-commercial; no editing; must link to the full article |
| MarketWatch, The Journal (Dow Jones) | RSS not to be used in a commercial product without consent (secondary quote) |
| Financial Times | Feeds for subscribers' personal use (old terms; current unread) |
| Times of India | Forbids aggregating feeds without consent (secondary source) |
| Condé Nast: Vogue, GQ, Wired, Pitchfork, AD, Bon Appétit, CN Traveler, Ars Technica | Terms unreadable by tool; reported personal-use only; photo-heavy |
| Penske: Variety, WWD, IndieWire, THR, Billboard | Paid bot access enforced; agency photos (Getty) |
| Hearst: Harper's Bazaar | Personal use only; fashion photography |

**Medium–High:** Washington Post (RSS terms; non-commercial per secondary source), Fortune
(RSS named in the commercial ban; no images elsewhere), SCMP (non-commercial, no competing
products, AI reserved), CNA (non-commercial RSS licence), Euronews (personal home use),
Skift (no excerpts without permission; AI needs a licence), The Points Guy (commercial use
prohibited; EU AI/TDM opt-out), Artnet News (images only on Artnet's own site).

**Medium:**
- **Terms unread or blocked from automated reading:** Vox Media (The Verge, Polygon, Eater,
  The Cut), Politico and Politico Europe, The Hill, STAT, The Hindu, Straits Times, Korea
  Herald, Japan Times, Sky News, Sky Sports, DW, The Independent, New Scientist, ABC
  Australia, Design Milk.
- **Non-commercial or anti-scraping wording:**
  - CBS News and CBS Sports (non-business; no index of their content)
  - CNBC, Forbes and The Local
  - Future plc: PC Gamer and Wallpaper* (domestic use; no photos apart from their text;
    TDM opt-out)
  - Highsnobiety, Hypebeast (bans aggregation), Dazed and i-D
  - ArchDaily, Colossal and designboom (free reuse only if non-commercial)
  - The Art Newspaper (no images apart from their text) and Dezeen (third-party images)
  - ESPN (allowed, but no modifying)
  - ScienceDaily (commercial use allowed, but no charging for it, no editing, no pictures)
  - Visual Capitalist (free under 5 employees / $1M revenue)
  - YouTube (robots.txt and personal-use terms)
  - The Splendid Table and Radiolab (public radio: non-commercial podcast feeds)

**Low–Medium:** ABC News, Yahoo Sports, Inverse, Stereogum, It's Nice That, Hyperallergic,
News in English.

**Low:** Medical Xpress, NASA, Our World in Data, TechCrunch, Engadget, the other podcasts.

**No terms found (text-led, likely low):** NME, Consequence, The Quietus, 9to5Mac, Eurogamer.

## What would lower the risk, most effective first

1. **Readers choose their outlets.** Today every outlet but the podcasts starts switched on
   (`OutletStore`, nil = all). Show the list as suggestions with nothing checked, or with a
   short starter set the reader confirms. This makes newnew a reader the person fills, as
   RSS readers have long been, not a service that serves publishers' content.
2. **Smaller pictures, no galleries for the strict outlets.**
   - Thumbnails on cards.
   - No full-width hero in the Top 10 reel for BBC, Guardian, Fortune, Future, the art and
     design titles and the fashion titles.
   - No fashion galleries.
   - No fetching a larger picture from the article page (LinkPresentation) for these outlets.
3. **Show descriptions unmodified:**
   - Show the feed's description whole when it is short, else none, at least for Fox, ESPN,
     ScienceDaily, Yahoo and TechCrunch, instead of cutting at 150 characters.
   - Keep the direct link and the outlet's name on every item ("Headline from X ↗" already
     does this). Add the credit wording some ask for: "BBC News", "NPR News Headlines",
     "ScienceDaily".
4. **The Apple Intelligence read off for outlets that reserve AI use:** Guardian, France 24,
   Al Jazeera, NYT, SCMP, Skift and The Points Guy. Or compare only the other outlets'
   headlines.
5. **Small fixes:**
   - Open Al Jazeera links in the publisher's app or Safari rather than the in-app Safari
     view.
   - Use the feed's own `hqdefault` YouTube thumbnail instead of checking for
     `maxresdefault`.
   - Link out (Apple Podcasts) for Radiolab and The Splendid Table instead of playing them
     in-app.
6. **Ask for permission where it matters most.** BBC (has an RSS/metadata licence), the
   Guardian (licensing team), CBC (commercial form), NPR, and the outlets you most want in
   the default list. A short "no objection" email from each covers a lot.
7. **A real takedown route.** publishers@newnew.news, with a promise to remove an outlet
   within 48 hours. Removing an outlet from `feeds.json` reaches every phone at its next
   refresh, with no app update.
8. **Read the blocked terms by hand:** Condé Nast, Vox, Penske, Hearst US, Washington Post,
   Politico, The Hill, Sky, DW, The Independent, New Scientist, ABC Australia, STAT, The
   Hindu, Straits Times, Korea Herald and Japan Times. Automated readers were refused, which
   itself shows those owners police automated and AI access.

## What this means for charging

A paid app makes the "personal, non-commercial" clauses bite. Ways to charge with less risk:

- **Charge only once readers choose their own outlets (step 1).** The app is then a paid
  reader, and the reader's own feeds are their personal use, as with Reeder or Unread. It
  should be in place before the paywall.
- **Make the suggested outlets mostly permissive or permitted ones:**
  - Feed licences that allow it (Medical Xpress, TechCrunch, Yahoo, ESPN, ABC News, NASA,
    OWID, podcasts).
  - Outlets that gave permission.
  - Everything else only when the reader adds it.
- **Or stay free**, which keeps newnew closest to the personal-use side.

## Read in a browser (17 Nov, later)

The pages that refused automated reading, read in Chrome:

| Owner | What the terms say | Now in newnew |
| --- | --- | --- |
| Condé Nast (Vogue, GQ, Wired, Pitchfork, AD, Bon Appétit, CN Traveler, Ars Technica), updated Oct 2024 | Content delivered by RSS falls under the same terms: personal, non-commercial use; no aggregating or scraping; no use for AI (training, fine-tuning, RAG) | No AI |
| Penske (Variety, WWD, IndieWire, THR, Billboard), Aug 2026 | Personal, non-commercial; no AI tools, robots or scraping | No AI |
| Hearst US (Harper's Bazaar), Oct 2025 | Personal, non-commercial; no AI or RAG; no tools to aggregate | No AI |
| Vox Media (Verge, Polygon, Eater, The Cut), Jul 2026 | Non-commercial; no robots or data-mining technology to cache, frame or extract | No AI |
| Washington Post (RSS terms) | Feeds allowed in a news reader; no more text than the feed gives; no editing or reformatting; keep links and by-line; credit the Post; pictures at most 60 × 60; on a mobile device only for one's own personal use | Verbatim, no pictures |
| Politico | Personal, non-commercial; nothing supplied to AI; no scraping or framing | No AI |
| Sky (News, Sports) | Personal, non-commercial home use; no aggregating or data mining; no AI tools | No AI |
| The Hill (Nexstar) | Personal, non-commercial; no use in any AI product | No AI |
| New Scientist | RSS for personal, non-commercial use; in a reader app the user must enable the feed themselves; no AI or text and data mining | No AI |
| Financial Times | No machine learning or AI use of content | No AI |
| ABC Australia | Personal, non-commercial; nothing on AI | — |
| DW | Only a legal notice; its RSS page sets no limits | — |

New Scientist's RSS page names a reader app and says the feeds may be used there when the
user enables them: support for readers choosing their outlets (done 17 Nov).

Still unread: Times of India (Chrome's extension refuses the site), STAT, The Hindu, Straits
Times, Korea Herald, Japan Times, The Independent (no terms link found), Eurogamer, NME,
Design Milk.

## Done in the app (17 Nov)

- Readers choose every outlet; new outlets are never switched on.
- Only the feed's own picture; none from article pages; a picture stays with its headline.
- `OutletRules`: verbatim outlets show no description; no-AI outlets are left out of Apple
  Intelligence's reads and of the server's breaking detection (`NO_MINING`); BBC,
  ScienceDaily and the Washington Post show no pictures; Al Jazeera opens outside newnew.
- The breaking push carries words, not a headline.
- The privacy page promises removal within 48 hours.

## How this was done

Four research passes read each publisher's RSS page and terms of use, or the owner's terms
for groups (Condé Nast, Vox, Penske, Future, Hearst, Yahoo, Paramount, Disney, Dow Jones).
Where pages refused automated reading, the review says "unread" and leans on search
excerpts or secondary sources, marked as such. Ratings are judgements for newnew's specific
use: headline, ≤ 150-character extract, feed picture, link out, on-device AI, paid app.

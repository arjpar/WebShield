import Foundation

private let baseUrl = "https://filters.adtidy.org/"
#if os(macOS)
    private let subUrl = "extension/safari"
    private let ifDesktopEnabled = false
#elseif os(iOS) || os(visionOS)
    private let subUrl = "ios"
    private let ifDesktopEnabled = true
#endif
private let filterSubUrl = "/filters"
private let partiallyFullUrl = baseUrl + subUrl + filterSubUrl

enum FilterListProvider {

    static let filterListData: [FilterListData] = [
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard – Ads",
            downloadUrl:
                "\(partiallyFullUrl)/2_optimized.txt",
            category: .ads,
            isSelected: true,
            description:
                "EasyList + AdGuard English filter. This filter is necessary for quality ad blocking.",
            homepageUrl:
                "https://github.com/AdguardTeam/AdguardFilters#adguard-filters",
            informationUrl:
                "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard – Mobile Ads",
            downloadUrl:
                "\(partiallyFullUrl)/11_optimized.txt",
            category: .ads,
            isSelected: ifDesktopEnabled,
            description:
                "Filter for all known mobile ad networks. Useful for mobile devices.",
            homepageUrl:
                "https://github.com/AdguardTeam/AdguardFilters#adguard-filters",
            informationUrl:
                "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "EasyList",
            downloadUrl:
                "\(partiallyFullUrl)/101_optimized.txt",
            category: .ads,
            isSelected: false,
            description:
                "EasyList is the primary subscription that removes adverts from web pages in English. Already included in AdGuard Base filter.",
            homepageUrl: "https://easylist.to/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard Tracking Protection",
            downloadUrl:
                "\(partiallyFullUrl)/3_optimized.txt",
            category: .privacy,
            isSelected: true,
            description:
                "The most comprehensive list of various online counters and web analytics tools. Use this filter if you do not want your actions on the Internet to be tracked.",
            homepageUrl:
                "https://github.com/AdguardTeam/AdguardFilters#adguard-filters",
            informationUrl:
                "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "EasyPrivacy",
            downloadUrl:
                "\(partiallyFullUrl)/118_optimized.txt",
            category: .privacy,
            isSelected: true,
            description:
                "Privacy protection supplement for EasyList.",
            homepageUrl: "https://easylist.to/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "Online Malicious URL Blocklist",
            downloadUrl:
                "\(partiallyFullUrl)/208_optimized.txt",
            category: .security,
            isSelected: false,
            description:
                "Blocks domains that are known to be used to propagate malware and spyware.",
            homepageUrl:
                "https://gitlab.com/malware-filter/urlhaus-filter#malicious-url-blocklist"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "Phishing URL Blocklist",
            downloadUrl:
                "\(partiallyFullUrl)/255_optimized.txt",
            category: .security,
            isSelected: false,
            description:
                "Phishing URL blocklist for uBlock Origin (uBO), AdGuard, Vivaldi, Pi-hole, Hosts file, Dnsmasq, BIND, Unbound, Snort and Suricata.",
            homepageUrl:
                "https://gitlab.com/malware-filter/phishing-filter#phishing-url-blocklist"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "Peter Lowe’s Ad and tracking server list",
            downloadUrl:
                "\(partiallyFullUrl)/204_optimized.txt",
            category: .multipurpose,
            isSelected: false,
            description:
                "Filter that blocks ads, trackers, and other nasty things.",
            homepageUrl: "https://pgl.yoyo.org/adservers/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "Hide YouTube Shorts",
            downloadUrl:
                "https://raw.githubusercontent.com/Harren06/ublock-yt-shorts/refs/heads/main/list.txt",
            category: .annoyances,
            isSelected: false,
            description:
                "Hide all traces of YouTube shorts videos on YouTube.",
            homepageUrl: "https://github.com/Harren06/ublock-yt-shorts"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "Bypass Paywalls Clean filter",
            downloadUrl:
                "https://gitflic.ru/project/magnolia1234/bypass-paywalls-clean-filters/blob/raw?file=bpc-paywall-filter.txt",
            category: .multipurpose,
            isSelected: false,
            description:
                "Filters for news sites (supports less sites than the extension/add-on).",
            homepageUrl:
                "https://gitflic.ru/project/magnolia1234/bypass-paywalls-clean-filters"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard – Cookie Notices",
            downloadUrl:
                "\(partiallyFullUrl)/18_optimized.txt",
            category: .cookies,
            isSelected: false,
            description:
                "Blocks cookie notices on web pages.",
            homepageUrl:
                "https://github.com/AdguardTeam/AdguardFilters#adguard-filters",
            informationUrl:
                "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "EasyList – Cookie Notices",
            downloadUrl:
                "\(partiallyFullUrl)/241_optimized.txt",
            category: .cookies,
            isSelected: false,
            description:
                "Removes cookie and privacy warnings. Already included in Fanboy's Annoyances list.",
            homepageUrl: "https://github.com/easylist/easylist#fanboy-lists"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard – Social Widgets",
            downloadUrl:
                "\(partiallyFullUrl)/4_optimized.txt",
            category: .social,
            isSelected: false,
            description:
                "Filter for social media widgets such as 'Like' and 'Share' buttons and more.",
            homepageUrl:
                "https://github.com/AdguardTeam/AdguardFilters#adguard-filters",
            informationUrl:
                "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "Fanboy – Social Blocking",
            downloadUrl:
                "\(partiallyFullUrl)/123_optimized.txt",
            category: .social,
            isSelected: false,
            description:
                "Hides and blocks social content, social widgets, social scripts and social icons. Already included in Fanboy's Annoyances list.",
            homepageUrl: "https://github.com/ryanbr/fanboy-adblock/issues"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "Fanboy – Anti-Facebook",
            downloadUrl:
                "\(partiallyFullUrl)/225_optimized.txt",
            category: .social,
            isSelected: false,
            description:
                "Warning, it will break Facebook-based comments on some websites and may also break some Facebook apps or games.",
            homepageUrl: "https://github.com/ryanbr/fanboy-adblock/issues"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard – Annoyances",
            downloadUrl:
                "\(partiallyFullUrl)/14_optimized.txt",
            category: .annoyances,
            isSelected: false,
            description:
                "Blocks irritating elements on web pages including cookie notices, third-party widgets and in-page pop-ups. Contains the following AdGuard filters: Cookie Notices, Popups, Mobile App Banners, Other Annoyances and Widgets.",
            homepageUrl:
                "https://github.com/AdguardTeam/AdguardFilters#adguard-filters",
            informationUrl:
                "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard – Popup Overlays",
            downloadUrl:
                "\(partiallyFullUrl)/19_optimized.txt",
            category: .annoyances,
            isSelected: false,
            description:
                "Blocks all kinds of pop-ups that are not necessary for websites' operation according to our Filter policy.",
            homepageUrl:
                "https://github.com/AdguardTeam/AdguardFilters#adguard-filters",
            informationUrl:
                "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard – Mobile App Banners",
            downloadUrl:
                "\(partiallyFullUrl)/20_optimized.txt",
            category: .annoyances,
            isSelected: false,
            description:
                "Blocks all kinds of pop-ups that are not necessary for websites' operation according to our Filter policy.",
            homepageUrl:
                "https://github.com/AdguardTeam/AdguardFilters#adguard-filters",
            informationUrl:
                "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard – Other Annoyances",
            downloadUrl:
                "\(partiallyFullUrl)/21_optimized.txt",
            category: .annoyances,
            isSelected: false,
            description:
                "Blocks irritating elements on web pages that do not fall under the popular categories of annoyances.",
            homepageUrl:
                "https://github.com/AdguardTeam/AdguardFilters#adguard-filters",
            informationUrl:
                "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard – Widgets",
            downloadUrl:
                "\(partiallyFullUrl)/22_optimized.txt",
            category: .annoyances,
            isSelected: false,
            description:
                "Blocks annoying third-party widgets: online assistants, live support chats, etc.",
            homepageUrl:
                "https://github.com/AdguardTeam/AdguardFilters#adguard-filters",
            informationUrl:
                "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "Fanboy – Annoyances",
            downloadUrl:
                "\(partiallyFullUrl)/122_optimized.txt",
            category: .annoyances,
            isSelected: false,
            description:
                "Removes in-page pop-ups and other annoyances. Includes Fanboy's Social Blocking & EasyList Cookie Lists.",
            homepageUrl: "https://github.com/ryanbr/fanboy-adblock/issues"
        ),

        FilterListData(
            id: UUID().uuidString,
            name: "🇷🇺ru: AdGuard Russian filter",
            downloadUrl:
                "\(partiallyFullUrl)/1_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Filter that enables ad blocking on websites in Russian language.",
            homepageUrl:
                "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇩🇪de: AdGuard German filter",
            downloadUrl:
                "\(partiallyFullUrl)/6_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "EasyList Germany + AdGuard German filter. Filter list that specifically removes ads on websites in German language.",
            homepageUrl:
                "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇯🇵jp: AdGuard Japanese filter",
            downloadUrl:
                "\(partiallyFullUrl)/7_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Filter that enables ad blocking on websites in Japanese language.",
            homepageUrl:
                "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇳🇱nl: AdGuard Dutch filter",
            downloadUrl:
                "\(partiallyFullUrl)/8_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "EasyList Dutch + AdGuard Dutch filter. Filter list that specifically removes ads on websites in Dutch language.",
            homepageUrl:
                "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇪🇸es🇦🇷ar🇵🇹pt🇧🇷br: AdGuard Spanish/Portuguese filter",
            downloadUrl:
                "\(partiallyFullUrl)/9_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Filter list that specifically removes ads on websites in Spanish, Portuguese, and Brazilian Portuguese languages.",
            homepageUrl:
                "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇹🇷tr: AdGuard Turkish filter",
            downloadUrl:
                "\(partiallyFullUrl)/13_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Filter list that specifically removes ads on websites in Turkish language.",
            homepageUrl:
                "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇫🇷fr: AdGuard French filter",
            downloadUrl:
                "\(partiallyFullUrl)/16_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Liste FR + AdGuard French filter. Filter list that specifically removes ads on websites in French language.",
            homepageUrl:
                "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇺🇦ua: AdGuard Ukrainian filter",
            downloadUrl:
                "\(partiallyFullUrl)/23_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Filter that enables ad blocking on websites in Ukrainian language.",
            homepageUrl:
                "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇮🇩id: ABPindo",
            downloadUrl:
                "\(partiallyFullUrl)/102_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in Indonesian.",
            homepageUrl:
                "https://github.com/ABPindo/indonesianadblockrules"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇧🇬bg: Bulgarian list",
            downloadUrl:
                "\(partiallyFullUrl)/103_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in Bulgarian.",
            homepageUrl:
                "https://github.com/RealEnder/adblockbg/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇨🇳cn🇹🇼tw: EasyList China",
            downloadUrl:
                "\(partiallyFullUrl)/104_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in Chinese. Already included in AdGuard Chinese filter.",
            homepageUrl:
                "https://github.com/easylist/easylistchina"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇨🇿cz: EasyList Czech and Slovak",
            downloadUrl:
                "\(partiallyFullUrl)/105_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in Czech and Slovak.",
            homepageUrl:
                "https://github.com/tomasko126/easylistczechandslovak"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇳🇱nl: EasyList Dutch",
            downloadUrl:
                "\(partiallyFullUrl)/106_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in Dutch. Already included in AdGuard Dutch filter.",
            homepageUrl:
                "https://github.com/easylist/easylistdutch/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇩🇪de: EasyList Germany",
            downloadUrl:
                "\(partiallyFullUrl)/107_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in German. Already included in AdGuard German filter.",
            homepageUrl:
                "https://github.com/easylist/easylistgermany/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇮🇱il: EasyList Hebrew",
            downloadUrl:
                "\(partiallyFullUrl)/108_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in Hebrew.",
            homepageUrl:
                "https://github.com/easylist/EasyListHebrew"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇮🇹it: EasyList Italy",
            downloadUrl:
                "\(partiallyFullUrl)/109_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in Italian.",
            homepageUrl:
                "https://github.com/easylist/easylistitaly/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇱🇹lt: EasyList Lithuania",
            downloadUrl:
                "\(partiallyFullUrl)/110_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in Lithuanian.",
            homepageUrl:
                "https://github.com/EasyList-Lithuania/easylist_lithuania"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇱🇻lv: Latvian List",
            downloadUrl:
                "\(partiallyFullUrl)/111_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in Latvian.",
            homepageUrl:
                "https://github.com/Latvian-List/adblock-latvian"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇸🇦sa: Liste AR",
            downloadUrl:
                "\(partiallyFullUrl)/112_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in Arabic.",
            homepageUrl:
                "https://github.com/easylist/listear"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇫🇷fr: Liste FR",
            downloadUrl:
                "\(partiallyFullUrl)/113_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in French. Already included in AdGuard French filter.",
            homepageUrl:
                "https://github.com/easylist/listefr"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇷🇴ro: ROList",
            downloadUrl:
                "\(partiallyFullUrl)/114_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in Romanian.",
            homepageUrl:
                "https://www.zoso.ro/rolist"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇮🇸is: Icelandic ABP List",
            downloadUrl:
                "\(partiallyFullUrl)/119_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in Icelandic.",
            homepageUrl:
                "https://adblock.gardar.net/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇮🇩id: AdBlockID",
            downloadUrl:
                "\(partiallyFullUrl)/120_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in Indonesian.",
            homepageUrl:
                "https://github.com/realodix/AdBlockID"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇬🇷gr: Greek AdBlock Filter",
            downloadUrl:
                "\(partiallyFullUrl)/121_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in Greek.",
            homepageUrl:
                "https://github.com/kargig/greek-adblockplus-filter"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇵🇹pt🇪🇸es: EasyList Portuguese",
            downloadUrl:
                "\(partiallyFullUrl)/124_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in Spanish and Portuguese.",
            homepageUrl:
                "https://github.com/easylist/easylistportuguese"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇹🇭th: EasyList Thailand",
            downloadUrl:
                "\(partiallyFullUrl)/202_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Filter that blocks ads on Thai sites.",
            homepageUrl:
                "https://github.com/easylist-thailand/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇭🇺hu: Hungarian filter",
            downloadUrl:
                "\(partiallyFullUrl)/203_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Hufilter. Filter list that specifically removes ads on websites in the Hungarian language.",
            homepageUrl:
                "https://github.com/hufilter/hufilter/wiki"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇮🇹it: Xfiles",
            downloadUrl:
                "\(partiallyFullUrl)/206_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Italian adblock filter list.",
            homepageUrl:
                "https://xfiles.noads.it/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇷🇺ru🇺🇦ua: RU AdList: Counters",
            downloadUrl:
                "\(partiallyFullUrl)/212_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "RU AdList supplement for trackers blocking.",
            homepageUrl:
                "https://forums.lanik.us/viewforum.php?f=102"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇻🇳vn: ABPVN List",
            downloadUrl:
                "\(partiallyFullUrl)/214_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Vietnamese adblock filter list.",
            homepageUrl:
                "https://abpvn.com/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name:
                "🇵🇱pl: Official Polish filters for AdBlock, uBlock Origin & AdGuard",
            downloadUrl:
                "\(partiallyFullUrl)/216_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in Polish.",
            homepageUrl:
                "https://github.com/MajkiIT/polish-ads-filter#polish-filters-for-adblock-ublock-origin--adguard"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇵🇱pl: Polish GDPR-Cookies Filters",
            downloadUrl:
                "\(partiallyFullUrl)/217_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Polish filter list for cookies blocking.",
            homepageUrl:
                "https://github.com/MajkiIT/polish-ads-filter#polish-filters-for-adblock-ublock-origin--adguard"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇪🇪ee: Estonian List",
            downloadUrl:
                "\(partiallyFullUrl)/218_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Filter for ad blocking on Estonian sites.",
            homepageUrl:
                "https://adblock.ee/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇨🇳cn🇹🇼tw: CJX's Annoyances List",
            downloadUrl:
                "\(partiallyFullUrl)/220_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Supplement for EasyList China+EasyList and EasyPrivacy.",
            homepageUrl:
                "https://github.com/cjx82630/cjxlist/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇵🇱pl: Polish Social Filters",
            downloadUrl:
                "\(partiallyFullUrl)/221_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Polish filter list for social widgets, popups, etc.",
            homepageUrl:
                "https://github.com/MajkiIT/polish-ads-filter#polish-filters-for-adblock-ublock-origin--adguard"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇨🇳cn🇹🇼tw: AdGuard Chinese filter",
            downloadUrl:
                "\(partiallyFullUrl)/224_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "EasyList China + AdGuard Chinese filter. Filter list that specifically removes ads on websites in Chinese language.",
            homepageUrl:
                "https://adguard.com/kb/general/ad-filtering/adguard-filters/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇰🇷kr: List-KR",
            downloadUrl:
                "\(partiallyFullUrl)/227_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Filter that removes ads and various scripts from websites with Korean content. Combined and augmented with AdGuard-specific rules for enhanced filtering. This filter is expected to be used alongside with AdGuard Base filter.",
            homepageUrl:
                "https://list-kr.github.io/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇨🇳cn🇹🇼tw: xinggsf",
            downloadUrl:
                "\(partiallyFullUrl)/228_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Blocks ads on the Chinese video platforms (MangoTV, DouYu and others).",
            homepageUrl:
                "https://github.com/xinggsf/Adblock-Plus-Rule/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇪🇸es: EasyList Spanish",
            downloadUrl:
                "\(partiallyFullUrl)/231_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in Spanish.",
            homepageUrl:
                "https://github.com/easylist/easylistspanish"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇵🇱pl: KAD - Anti-Scam",
            downloadUrl:
                "\(partiallyFullUrl)/232_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Filter that protects against various types of scams in the Polish network, such as mass text messaging, fake online stores, etc.",
            homepageUrl:
                "https://github.com/FiltersHeroes/KAD"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇫🇮fi: Adblock List for Finland",
            downloadUrl:
                "\(partiallyFullUrl)/233_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Finnish ad blocking filter list.",
            homepageUrl:
                "https://github.com/finnish-easylist-addition/finnish-easylist-addition"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇷🇴ro: ROLIST2",
            downloadUrl:
                "\(partiallyFullUrl)/234_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "This is a complementary list for ROList with annoyances that are not necessarily banners. It is a very aggressive list and not recommended for beginners.",
            homepageUrl:
                "https://zoso.ro/rolist/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇮🇷ir: Persian Blocker",
            downloadUrl:
                "\(partiallyFullUrl)/235_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Filter list for blocking ads and trackers on websites in Persian.",
            homepageUrl:
                "https://github.com/MasterKia/PersianBlocker/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇷🇴ro: road-block light",
            downloadUrl:
                "\(partiallyFullUrl)/236_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Romanian ad blocking filter subscription.",
            homepageUrl:
                "https://github.com/tcptomato/ROad-Block"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇵🇱pl: Polish Annoyances Filters",
            downloadUrl:
                "\(partiallyFullUrl)/237_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Filter list that hides and blocks pop-ups, widgets, newsletters, push notifications, arrows, tagged internal links that are off-topic, and other irritating elements. Polish GDPR-Cookies Filters is already in it.",
            homepageUrl:
                "https://polishannoyancefilters.netlify.app"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇵🇱pl: Polish Anti Adblock Filters",
            downloadUrl:
                "\(partiallyFullUrl)/238_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Official Polish filters against Adblock alerts.",
            homepageUrl:
                "https://github.com/olegwukr/polish-privacy-filters"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇸🇪se: Frellwit's Swedish Filter",
            downloadUrl:
                "\(partiallyFullUrl)/243_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Filter that aims to remove regional Swedish ads, tracking, social media, annoyances, sponsored articles etc.",
            homepageUrl:
                "https://github.com/lassekongo83/Frellwit-s-filter-lists"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇰🇷kr: YousList",
            downloadUrl:
                "\(partiallyFullUrl)/244_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Filter that blocks ads on Korean sites.",
            homepageUrl:
                "https://github.com/yous/YousList/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇵🇱pl: EasyList Polish",
            downloadUrl:
                "\(partiallyFullUrl)/246_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in Polish.",
            homepageUrl:
                "https://github.com/easylistpolish/easylistpolish/"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇵🇱pl: Polish Anti-Annoying Special Supplement",
            downloadUrl:
                "\(partiallyFullUrl)/247_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Filters that block and hide RSS elements and remnants of hidden newsletters combined with social elements on Polish websites.",
            homepageUrl:
                "https://github.com/PolishFiltersTeam/PolishAntiAnnoyingSpecialSupplement"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇳🇴no: Dandelion Sprout's Nordic Filters",
            downloadUrl:
                "\(partiallyFullUrl)/249_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "This list covers websites for Norway, Denmark, Iceland, Danish territories, and the Sami indigenous population.",
            homepageUrl:
                "https://github.com/DandelionSprout/adfilt"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇷🇸rs🇲🇪me🇭🇷hr🇧🇦ba: Dandelion Sprout's Serbo-Croatian List",
            downloadUrl:
                "\(partiallyFullUrl)/252_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "A filter list for websites in Serbian, Montenegrin, Croatian, and Bosnian.",
            homepageUrl:
                "https://github.com/DandelionSprout/adfilt"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇮🇳in: IndianList",
            downloadUrl:
                "\(partiallyFullUrl)/253_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Additional filter list for websites in Hindi, Tamil and other Dravidian and Indic languages.",
            homepageUrl:
                "https://github.com/mediumkreation/IndianList"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "🇲🇰mk: Macedonian adBlock Filters",
            downloadUrl:
                "\(partiallyFullUrl)/254_optimized.txt",
            category: .regional,
            isSelected: false,
            description:
                "Blocks ads and trackers on various Macedonian websites.",
            homepageUrl:
                "https://github.com/DeepSpaceHarbor/Macedonian-adBlock-Filters"
        ),

        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard – Experimental",
            downloadUrl:
                "\(partiallyFullUrl)/5_optimized.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Filter designed to test certain hazardous filtering rules before they are added to the basic filters.",
            homepageUrl:
                "https://github.com/AdguardTeam/AdguardFilters#adguard-filters"
        ),

        FilterListData(
            id: UUID().uuidString,
            name: "ABP Test Pages Filter",
            downloadUrl:
                "https://abptestpages.org/en/abp-testcase-subscription.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://abptestpages.org"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard Tests - Element Hiding Rules",
            downloadUrl:
                "https://testcases.agrd.dev/Filters/element-hiding-rules/test-element-hiding-rules.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://testcases.agrd.dev"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard Tests - Generic Hiding Rules",
            downloadUrl:
                "https://testcases.agrd.dev/Filters/generichide-rules/generichide-rules.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://testcases.agrd.dev"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard Tests - CSS Rules",
            downloadUrl:
                "https://testcases.agrd.dev/Filters/css-rules/css-rules.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://testcases.agrd.dev"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard Tests - Extended CSS Rules",
            downloadUrl:
                "https://testcases.agrd.dev/Filters/extended-css-rules/test-extended-css-rules.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://testcases.agrd.dev"
        ),
        FilterListData(
            id: UUID().uuidString,
            name:
                "AdGuard Tests - Extended CSS rules injection into iframe created with js",
            downloadUrl:
                "https://testcases.agrd.dev/Filters/extended-css-rules/extended-css-iframejs-injection/extended-css-iframejs-injection.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://testcases.agrd.dev"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard Tests - $important rules",
            downloadUrl:
                "https://testcases.agrd.dev/Filters/important-rules/test-important-rules.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://testcases.agrd.dev"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard Tests - WebSocket blocking",
            downloadUrl:
                "https://testcases.agrd.dev/Filters/websockets/test-websockets.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://testcases.agrd.dev"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard Tests - Script rules",
            downloadUrl:
                "https://testcases.agrd.dev/Filters/script-rules/test-script-rules.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://testcases.agrd.dev"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard Tests - Scriptlet rules",
            downloadUrl:
                "https://testcases.agrd.dev/Filters/scriptlet-rules/test-scriptlet-rules.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://testcases.agrd.dev"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard Tests - Popup blocker",
            downloadUrl:
                "https://testcases.agrd.dev/PopupBlocker/test-popup-blocker-rules.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://testcases.agrd.dev"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard Tests - $badfilter rules",
            downloadUrl:
                "https://testcases.agrd.dev/Filters/badfilter-rules/test-badfilter-rules.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://testcases.agrd.dev"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard Tests - $jsinject rules test",
            downloadUrl:
                "https://testcases.agrd.dev/Filters/script-rules/jsinject-rules/test-jsinject-rules.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://testcases.agrd.dev"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard Tests - $denyallow rules",
            downloadUrl:
                "https://testcases.agrd.dev/Filters/denyallow-rules/test-denyallow-rules.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://testcases.agrd.dev"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard Tests - $ping,$websocket,$xmlhttprequest rules",
            downloadUrl:
                "https://testcases.agrd.dev/Filters/blocking-request-rules/test-blocking-request-rules.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://testcases.agrd.dev"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard Tests - Test $subdocoument rules for Safari 15+",
            downloadUrl:
                "https://testcases.agrd.dev/Filters/subdocument-rules/test-subdocument-rules.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://testcases.agrd.dev"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard Tests - Non-basic $path modifier",
            downloadUrl:
                "https://testcases.agrd.dev/Filters/nonbasic-path-modifier/test-nonbasic-path-modifier.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://testcases.agrd.dev"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard Tests - $match-case modifier tests",
            downloadUrl:
                "https://testcases.agrd.dev/Filters/match-case-rules/test-match-case-rules.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://testcases.agrd.dev"
        ),
        FilterListData(
            id: UUID().uuidString,
            name:
                "AdGuard Tests - JS and Scriptlet rules: Content Security Policy (CSP) tests",
            downloadUrl:
                "https://testcases.agrd.dev/Filters/content-security-policy/test-content-security-policy.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://testcases.agrd.dev"
        ),
        FilterListData(
            id: UUID().uuidString,
            name: "AdGuard Tests - Injection speed tests",
            downloadUrl:
                "https://testcases.agrd.dev/Filters/injection-speed/test-injection-speed.txt",
            category: .experimental,
            isSelected: false,
            description:
                "Used for internal development for the validation and verification of WebShield's content blocking capabilities. Unless what you know what you're doing, or are told by developers to enable this list for testing, you need not enable it.",
            homepageUrl: "https://testcases.agrd.dev"
        )

    ]

    static func filterListDataById(_ id: String) -> FilterListData? {
        return filterListData.first(where: { $0.id == id })
    }
}

import Foundation

// The critique panel: the photographers a photo is judged against, chosen by the photographer (onboarding,
// Settings). The critique has six seats; each seat covers some of the criteria and is held by one panel
// member. A panel of one to six is seated by fit (each member's strength at each seat), so everyone chosen
// judges something. The original six (StudioAI.panel) keep the hand-written brief exactly as it was.

/// One seat on the panel and the criteria it judges.
struct PanelSeat {
    let id: String
    let label: String          // for people: "Light", "Moment & wit", ...
    let brief: String          // for the system prompt: "LIGHT", "WIT and the MOMENT", ...
    let question: String       // what the seat asks, after "<Surname> asks"
    let criteria: [String]     // "picture.light", ...
}

struct Photographer {
    let id: String
    let name: String
    let surname: String
    let known: String          // one line: what they're known for
    let genres: [String]       // street, colour, bw, documentary, landscape, portrait
    let work: String           // what made their work great (for the brief, and shown in the picker)
    let strengths: [String: Int]   // seat id -> 0...3
    let palette: [String]      // three colours for the picker
    let film: String           // suggested starting look (StudioStarter id)
}

enum StudioPanel {
    static let seats: [PanelSeat] = [
        PanelSeat(id: "light", label: "Light", brief: "LIGHT",
                  question: "whether the light is doing something: its quality and direction on the subject, and whether the colour or tone it makes is true and alive without being forced.",
                  criteria: ["picture.light"]),
        PanelSeat(id: "moment", label: "Moment & wit", brief: "WIT and the MOMENT",
                  question: "whether something is happening and is caught at its peak, and whether there is wit: a visual joke, a coincidence, a juxtaposition, a gesture that becomes more than itself.",
                  criteria: ["picture.moment", "picture.wit"]),
        PanelSeat(id: "composition", label: "Composition & subject", brief: "COMPOSITION and SUBJECT",
                  question: "whether the frame is balanced and controlled to its edges, whether its layers work or just clutter, and whether the picture is clearly about something.",
                  criteria: ["picture.composition", "picture.subject"]),
        PanelSeat(id: "color", label: "Colour & crispness", brief: "the print's COLOUR, SATURATION and CRISPNESS",
                  question: "whether the colour is balanced and true (whites, skin, sky, neutrals), whether it is rich without tipping into neon, and whether detail holds where it matters.",
                  criteria: ["print.color", "print.saturation", "print.crispness"]),
        PanelSeat(id: "density", label: "Density & contrast", brief: "the print's DENSITY and CONTRAST",
                  question: "whether the print has weight while staying readable, or whether it is crushed, muddy, overcooked, too dark or too flat.",
                  criteria: ["print.density", "print.contrast"]),
        PanelSeat(id: "restraint", label: "Restraint", brief: "RESTRAINT, in the VIGNETTE and in any effect",
                  question: "whether anything in the print calls attention to itself: darkened corners, extra punch, extra saturation, an edit you can see.",
                  criteria: ["print.vignette"]),
    ]

    /// The original panel, by catalog id, in StudioAI.panel order.
    static let defaultIds = ["meyerowitz", "levitt", "davidson", "eggleston", "leiter", "webb"]
    static let maxPanel = 6

    // Strengths: light, moment, composition, color, density, restraint.
    private static func s(_ l: Int, _ m: Int, _ c: Int, _ k: Int, _ d: Int, _ r: Int) -> [String: Int] {
        ["light": l, "moment": m, "composition": c, "color": k, "density": d, "restraint": r]
    }

    static let catalog: [Photographer] = [
        Photographer(id: "meyerowitz", name: "Joel Meyerowitz", surname: "Meyerowitz", known: "Fifth Avenue in the 1960s and 70s, on Kodachrome",
                     genres: ["street", "colour"],
                     work: "He took colour into the street when serious photographers still worked in black and white, with a Leica and Kodachrome. His pictures are about the whole field, not one subject: several unrelated things happening at once, held together by the light. Light is his subject: a hard edge of sun, a glow in shade, light turning ordinary colour into an event.",
                     strengths: s(3, 2, 2, 2, 1, 2), palette: ["#e2a13b", "#2f6db5", "#c23b22"], film: "kodachrome"),
        Photographer(id: "levitt", name: "Helen Levitt", surname: "Levitt", known: "New York street life as theatre",
                     genres: ["street", "colour", "bw"],
                     work: "On the streets of New York she caught everyday life as theatre: children playing, gestures between strangers, bodies doing something funny or tender, always with affection, never mockery. Her colour work of the 1970s kept the same eye.",
                     strengths: s(1, 3, 2, 1, 1, 2), palette: ["#c8553d", "#3d6b8c", "#e3c16f"], film: "kodachrome"),
        Photographer(id: "webb", name: "Alex Webb", surname: "Webb", known: "Layered colour in hard tropical light",
                     genres: ["street", "colour"],
                     work: "His frames are built in layers: hard light and deep shadow carve the picture into compartments, each with a figure or event, and every edge is active. Complex but never confused.",
                     strengths: s(2, 2, 3, 2, 2, 1), palette: ["#d4561c", "#1f3f7a", "#e8b23a"], film: "kodachrome"),
        Photographer(id: "eggleston", name: "William Eggleston", surname: "Eggleston", known: "The everyday in dye-transfer colour",
                     genres: ["colour"],
                     work: "He found the extraordinary in ordinary things and made colour itself the subject, printed by dye transfer: deep, rich, exact colour that is never garish.",
                     strengths: s(2, 1, 2, 3, 2, 2), palette: ["#2f7a6f", "#c73f3a", "#e6d28a"], film: "kodachrome"),
        Photographer(id: "davidson", name: "Bruce Davidson", surname: "Davidson", known: "Subway, 1980s New York",
                     genres: ["street", "documentary", "colour", "bw"],
                     work: "His Subway pictures of 1980s New York are dense, dark, saturated and tough, with weight in the shadows, but you can always read the people.",
                     strengths: s(1, 2, 2, 2, 3, 1), palette: ["#3b3f52", "#b8432f", "#d9b44a"], film: "kodachrome"),
        Photographer(id: "leiter", name: "Saul Leiter", surname: "Leiter", known: "Painterly New York colour",
                     genres: ["street", "colour"],
                     work: "His New York colour is quiet and painterly: small accents of colour, soft layers of glass, snow and shadow, nothing forced.",
                     strengths: s(2, 1, 2, 2, 1, 3), palette: ["#b84a3a", "#d8c7a6", "#5a6b4a"], film: "kodachrome"),
        Photographer(id: "gruyaert", name: "Harry Gruyaert", surname: "Gruyaert", known: "Colour fields: Morocco, Belgium, airports",
                     genres: ["street", "colour"],
                     work: "He builds pictures from blocks of saturated colour and light: Moroccan walls, Belgian shopfronts, the glow of a television, the emptiness of an airport. Colour is the structure of the frame, not decoration on it.",
                     strengths: s(2, 1, 2, 3, 2, 1), palette: ["#c8352a", "#1d5e5a", "#e6c44a"], film: "ektachrome"),
        Photographer(id: "herzog", name: "Fred Herzog", surname: "Herzog", known: "Vancouver on Kodachrome, 1950s and 60s",
                     genres: ["street", "colour"],
                     work: "He photographed the street life of Vancouver on Kodachrome slides when colour was thought commercial: neon signs, shop windows, pedestrians, cars, barbershops. Warm, honest, everyday colour and patient, unhurried composition.",
                     strengths: s(2, 2, 2, 3, 1, 2), palette: ["#2e5fa8", "#d23b2c", "#e0b84a"], film: "kodachrome"),
        Photographer(id: "shore", name: "Stephen Shore", surname: "Shore", known: "Uncommon Places, 8×10 colour",
                     genres: ["colour", "landscape"],
                     work: "On road trips across America in the 1970s he made large-format colour pictures of intersections, motel rooms and main streets, seen with complete clarity. Every element is placed; the light is plain, the colour even and exact, nothing is dramatised.",
                     strengths: s(2, 0, 3, 2, 1, 3), palette: ["#8aa8c8", "#d9c49a", "#7a8a5a"], film: "portra"),
        Photographer(id: "cartier-bresson", name: "Henri Cartier-Bresson", surname: "Cartier-Bresson", known: "Geometry and the decisive moment",
                     genres: ["street", "bw", "documentary"],
                     work: "With a Leica and black-and-white film he waited for the instant when the geometry of a place and the event in it lock together. His frames are composed to the edge and were never cropped afterwards.",
                     strengths: s(1, 3, 3, 0, 1, 2), palette: ["#2a2a2a", "#8a8a8a", "#e0e0e0"], film: "bw"),
        Photographer(id: "moriyama", name: "Daido Moriyama", surname: "Moriyama", known: "Tokyo in grain, blur and contrast",
                     genres: ["street", "bw"],
                     work: "His black and white of Shinjuku is grainy, blurred and harsh: raw energy over polish, the city as sensation. Contrast and grain are the point, and still the picture has to hit.",
                     strengths: s(1, 2, 1, 0, 3, 0), palette: ["#111111", "#5a5a5a", "#d8d8d8"], film: "bw"),
        Photographer(id: "maier", name: "Vivian Maier", surname: "Maier", known: "Chicago and New York with a Rolleiflex",
                     genres: ["street", "bw", "portrait"],
                     work: "Working from waist level with a Rolleiflex, she made direct, unsentimental street portraits, reflections and self-portraits, children and the old, often with a quiet wit. Her work was found only after her death.",
                     strengths: s(1, 3, 2, 0, 1, 2), palette: ["#3a3a3a", "#9a9a9a", "#e6e6e6"], film: "bw"),
        Photographer(id: "fan-ho", name: "Fan Ho", surname: "Fan Ho", known: "Light and shadow in 1950s Hong Kong",
                     genres: ["street", "bw"],
                     work: "In 1950s and 60s Hong Kong he placed small figures in vast fields of light, smoke and long shadow across alleys and stairways. Pure geometry, and prints worked by hand until the light sang.",
                     strengths: s(3, 1, 3, 0, 2, 2), palette: ["#1a1a1a", "#6e6e6e", "#eaeaea"], film: "bw"),
        Photographer(id: "parr", name: "Martin Parr", surname: "Parr", known: "Flash, saturation and satire",
                     genres: ["documentary", "colour"],
                     work: "With ring flash and saturated colour he photographed beaches, tourists and food: a satire of leisure and consumption, affectionate and merciless at once. Loud colour on purpose, and always a point.",
                     strengths: s(0, 3, 1, 2, 1, 0), palette: ["#e84a8a", "#3aa0d8", "#f0d23a"], film: "superia"),
        Photographer(id: "winogrand", name: "Garry Winogrand", surname: "Winogrand", known: "1960s America through a wide angle",
                     genres: ["street", "bw"],
                     work: "He shot obsessively with a wide lens: tilted frames, crowds, gestures, animals at the zoo, the whole of public life at once. The energy is barely held together, and that tension is the picture.",
                     strengths: s(1, 3, 2, 0, 1, 1), palette: ["#2d2d2d", "#7d7d7d", "#dcdcdc"], film: "bw"),
        Photographer(id: "friedlander", name: "Lee Friedlander", surname: "Friedlander", known: "The American social landscape",
                     genres: ["street", "bw"],
                     work: "His frames are crowded on purpose with poles, signs, reflections, fences and his own shadow, everything sharp, layered to the edge and full of visual puns. Nothing in the frame is accidental.",
                     strengths: s(1, 2, 3, 0, 1, 1), palette: ["#303030", "#858585", "#d6d6d6"], film: "bw"),
        Photographer(id: "frank", name: "Robert Frank", surname: "Frank", known: "The Americans",
                     genres: ["street", "bw", "documentary"],
                     work: "Crossing the country in the 1950s he made loose, grainy, dark pictures of jukeboxes, flags, cars and faces: feeling over polish, mood over correctness.",
                     strengths: s(2, 2, 1, 0, 2, 1), palette: ["#262626", "#6b6b6b", "#c9c9c9"], film: "bw"),
        Photographer(id: "haas", name: "Ernst Haas", surname: "Haas", known: "Colour in motion, on Kodachrome",
                     genres: ["street", "colour"],
                     work: "An early master of colour, he worked in Kodachrome with reflections, puddles, blur and motion, finding abstraction in the street. Colour and light carry the picture.",
                     strengths: s(3, 1, 2, 3, 1, 1), palette: ["#c43a2d", "#2c5d9e", "#e9a93a"], film: "kodachrome"),
        Photographer(id: "erwitt", name: "Elliott Erwitt", surname: "Erwitt", known: "Humour, dogs and coincidence",
                     genres: ["street", "bw"],
                     work: "His pictures are deadpan comedy: dogs, couples, coincidences of scale and gesture, caught simply and without fuss. The joke is always in the frame, never added.",
                     strengths: s(1, 3, 2, 0, 1, 2), palette: ["#333333", "#8f8f8f", "#e2e2e2"], film: "bw"),
        Photographer(id: "salgado", name: "Sebastião Salgado", surname: "Salgado", known: "Workers and Genesis in epic black and white",
                     genres: ["documentary", "landscape", "bw"],
                     work: "His black and white has an enormous tonal range: luminous skies, deep blacks that still open up, every grey in between, on subjects from gold miners to untouched landscapes.",
                     strengths: s(3, 1, 2, 0, 3, 2), palette: ["#1c1c1c", "#777777", "#efefef"], film: "bw"),
        Photographer(id: "adams", name: "Ansel Adams", surname: "Adams", known: "Yosemite and the Zone System",
                     genres: ["landscape", "bw"],
                     work: "He planned every print before exposure with the Zone System: the full scale from black to white, detail in the shadows and the snow, light carved across mountains and sky.",
                     strengths: s(3, 0, 2, 0, 3, 2), palette: ["#151515", "#808080", "#f2f2f2"], film: "bw"),
        Photographer(id: "arbus", name: "Diane Arbus", surname: "Arbus", known: "Square portraits, face to face",
                     genres: ["portrait", "bw", "documentary"],
                     work: "Her square, frontal portraits of people on the margins and of ordinary families look straight back at you. Direct, unflinching, with nothing between the viewer and the subject.",
                     strengths: s(1, 2, 3, 0, 2, 2), palette: ["#2b2b2b", "#8c8c8c", "#e4e4e4"], film: "bw"),
        Photographer(id: "lange", name: "Dorothea Lange", surname: "Lange", known: "The Depression, with empathy",
                     genres: ["documentary", "bw", "portrait"],
                     work: "Her documentary work of the 1930s reads faces, hands and posture with deep empathy. The picture serves the person in it.",
                     strengths: s(2, 3, 2, 0, 2, 2), palette: ["#2f2f2f", "#939393", "#dedede"], film: "bw"),
        Photographer(id: "parks", name: "Gordon Parks", surname: "Parks", known: "Life magazine and the civil rights era",
                     genres: ["documentary", "colour", "bw", "portrait"],
                     work: "In colour and black and white he photographed American life and segregation with dignity and a storyteller's sense of the frame. Each picture carries a narrative and respects the people in it.",
                     strengths: s(2, 2, 2, 2, 2, 2), palette: ["#7a4b2a", "#3c6e8f", "#d9b27c"], film: "kodachrome"),
        Photographer(id: "sternfeld", name: "Joel Sternfeld", surname: "Sternfeld", known: "American Prospects, 8×10 colour",
                     genres: ["colour", "landscape"],
                     work: "His large-format colour of late-1970s America is soft, even and quietly ironic: small human events inside wide landscapes, said without raising the voice.",
                     strengths: s(2, 2, 3, 2, 1, 3), palette: ["#d58b5f", "#8fb0c4", "#a3a77a"], film: "portra"),
        Photographer(id: "kawauchi", name: "Rinko Kawauchi", surname: "Kawauchi", known: "Soft daylight and small moments",
                     genres: ["colour"],
                     work: "Her pictures are pale, soft and full of daylight: small everyday moments, square frames, colour held back to a whisper. Quiet is the point.",
                     strengths: s(3, 1, 2, 2, 0, 3), palette: ["#efe3d3", "#bcd3d6", "#e8b9a8"], film: "portra"),
        Photographer(id: "goldin", name: "Nan Goldin", surname: "Goldin", known: "The Ballad of Sexual Dependency",
                     genres: ["documentary", "colour", "portrait"],
                     work: "Her flash-lit colour diary of friends and lovers is saturated, raw and intimate. Honesty matters more than polish.",
                     strengths: s(1, 3, 1, 2, 2, 0), palette: ["#b32d4a", "#2c3e75", "#e0a35b"], film: "superia"),
        Photographer(id: "parke", name: "Trent Parke", surname: "Parke", known: "Harsh Australian light",
                     genres: ["street", "colour", "bw"],
                     work: "In Sydney's streets he works with hard golden light and deep shadow, people lit like actors on a stage, in black and white and in colour.",
                     strengths: s(3, 2, 2, 1, 2, 1), palette: ["#e3a23c", "#1e1e1e", "#9a6b3a"], film: "kodachrome"),
        Photographer(id: "koudelka", name: "Josef Koudelka", surname: "Koudelka", known: "Gypsies and Exiles",
                     genres: ["documentary", "bw"],
                     work: "His black and white is stark, dark and dramatically composed: Prague in 1968, Roma communities, a life in exile. Strong shapes, deep blacks, nothing soft.",
                     strengths: s(1, 2, 3, 0, 3, 1), palette: ["#141414", "#676767", "#dddddd"], film: "bw"),
        Photographer(id: "singh", name: "Raghubir Singh", surname: "Singh", known: "The colour of India",
                     genres: ["street", "colour"],
                     work: "His frames of India are dense with layered colour and many events at once, held together with control. He showed that colour could be the language of a whole country.",
                     strengths: s(2, 2, 3, 3, 1, 1), palette: ["#d2462e", "#e5b52f", "#2c7a6a"], film: "ektachrome"),
        Photographer(id: "avedon", name: "Richard Avedon", surname: "Avedon", known: "Portraits on white",
                     genres: ["portrait", "bw"],
                     work: "Against a plain white backdrop he stripped away everything but the person: precise, unforgiving portraits where every detail of face and posture counts.",
                     strengths: s(1, 2, 3, 0, 2, 3), palette: ["#f4f4f4", "#9e9e9e", "#2a2a2a"], film: "bw"),
        Photographer(id: "sugimoto", name: "Hiroshi Sugimoto", surname: "Sugimoto", known: "Seascapes and long exposures",
                     genres: ["landscape", "bw"],
                     work: "His seascapes and theatres are silent, exact studies of time and light, with the subtlest greys. Nothing extra, nothing loud.",
                     strengths: s(2, 0, 3, 0, 2, 3), palette: ["#3c3c3c", "#a6a6a6", "#e9e9e9"], film: "bw"),
        Photographer(id: "stuart", name: "Matt Stuart", surname: "Stuart", known: "London street coincidences",
                     genres: ["street", "colour"],
                     work: "On London's streets he waits for alignments and coincidences that turn the everyday into a joke, framed cleanly so the gag reads at once.",
                     strengths: s(1, 3, 2, 1, 1, 2), palette: ["#c9302c", "#2a5c8a", "#e8c547"], film: "superia"),
        Photographer(id: "mermelstein", name: "Jeff Mermelstein", surname: "Mermelstein", known: "New York's strangeness, in colour",
                     genres: ["street", "colour"],
                     work: "He finds the odd, the funny and the unsettling in New York's crowds, close up and in colour, often in a single surprising detail.",
                     strengths: s(1, 3, 2, 2, 1, 1), palette: ["#d64a3a", "#3a7ab8", "#f0c14b"], film: "superia"),
        Photographer(id: "gilden", name: "Bruce Gilden", surname: "Gilden", known: "Flash in faces on Fifth Avenue",
                     genres: ["street", "bw", "portrait"],
                     work: "He steps in close with a flash and catches people mid-stride: confrontational, physical, full of character. Impact over politeness.",
                     strengths: s(1, 3, 1, 0, 2, 0), palette: ["#181818", "#5f5f5f", "#e5e5e5"], film: "bw"),
        Photographer(id: "hido", name: "Todd Hido", surname: "Hido", known: "Houses at night, colour in fog",
                     genres: ["colour", "landscape"],
                     work: "His suburban houses at night and landscapes through a fogged windshield are about mood and light: soft colour, long exposures, a feeling of being outside looking in.",
                     strengths: s(3, 0, 2, 2, 2, 2), palette: ["#3e4f6a", "#c48b4a", "#8a9aa3"], film: "portra"),
    ]

    /// Ready-made panels by style: most people know the kind of photography they want judged by before
    /// they know names. "Choose your own" (any catalog photographers) stays one level deeper.
    static let groups: [(id: String, name: String, note: String, ids: [String], seats: [String: String])] = [
        ("new-york", "New York Street", "Fifth Avenue, the subway and the street as theatre, in colour and black and white.",
         ["meyerowitz", "levitt", "winogrand", "mermelstein", "davidson", "leiter"],
         ["light": "meyerowitz", "moment": "levitt", "composition": "winogrand", "color": "mermelstein", "density": "davidson", "restraint": "leiter"]),
        ("colour", "Colour Masters", "Colour as the subject: dye transfer, Kodachrome, saturated light and layered frames.",
         ["eggleston", "webb", "haas", "gruyaert", "herzog", "singh"],
         ["light": "haas", "moment": "singh", "composition": "webb", "color": "eggleston", "density": "gruyaert", "restraint": "herzog"]),
        ("bw-street", "Black-and-White Street", "Geometry, the decisive moment, grain and contrast.",
         ["cartier-bresson", "fan-ho", "friedlander", "moriyama", "maier"],
         ["light": "fan-ho", "moment": "cartier-bresson", "composition": "cartier-bresson", "color": "friedlander", "density": "moriyama", "restraint": "maier"]),
        ("documentary", "Documentary and Portrait", "People, history and empathy: faces, hands and the story in them.",
         ["lange", "parks", "salgado", "koudelka", "arbus", "avedon"],
         ["light": "salgado", "moment": "lange", "composition": "arbus", "color": "parks", "density": "koudelka", "restraint": "avedon"]),
        ("quiet", "Quiet and Precise", "Plain light, exact colour and stillness, from large-format America to soft daylight.",
         ["shore", "sternfeld", "kawauchi", "hido", "sugimoto", "adams"],
         ["light": "kawauchi", "moment": "sternfeld", "composition": "shore", "color": "hido", "density": "adams", "restraint": "sugimoto"]),
        ("wit", "Wit and the Absurd", "Coincidence, comedy and the odd moment that makes you look twice.",
         ["erwitt", "levitt", "stuart", "parr", "mermelstein"],
         ["light": "levitt", "moment": "erwitt", "composition": "stuart", "color": "parr", "density": "mermelstein", "restraint": "erwitt"]),
    ]
    static func groupId(_ ids: [String]) -> String? { groups.first { Set($0.ids) == Set(ids) }?.id }

    static let genres: [(id: String, label: String)] = [
        ("street", "Street"), ("colour", "Colour"), ("bw", "Black & white"), ("documentary", "Documentary"),
        ("landscape", "Landscape"), ("portrait", "Portrait"),
    ]

    static func photographer(_ id: String) -> Photographer? { catalog.first { $0.id == id } }

    /// Known ids only, no duplicates, at most six, in the given order.
    static func clean(_ ids: [String]) -> [String] {
        var out: [String] = []
        for id in ids where photographer(id) != nil && !out.contains(id) { out.append(id) }
        return Array(out.prefix(maxPanel))
    }

    /// The original brief and seats: only a library from before panels could be chosen (no panel stored). A panel
    /// anyone picks, even the same six names, gets the brief written from the catalog.
    static func isDefault(_ ids: [String]?) -> Bool { ids == nil }

    /// seat id -> photographer id. Every member gets at least one seat; the total fit is as high as possible,
    /// seats spread evenly on a tie; ties after that go to the earlier member in the list.
    static func seat(_ ids0: [String]) -> [String: String] {
        let ids = clean(ids0)
        if isDefault(ids) || ids.isEmpty {
            return ["light": "meyerowitz", "moment": "levitt", "composition": "webb", "color": "eggleston", "density": "davidson", "restraint": "leiter"]
        }
        // A ready-made group is seated by hand.
        if let g = groups.first(where: { Set($0.ids) == Set(ids) }) { return g.seats }
        let people = ids.compactMap(photographer)
        let n = people.count, k = seats.count
        var best: [Int] = [], bestScore = -Double.infinity
        var a = [Int](repeating: 0, count: k)
        var total = 1
        for _ in 0..<k { total *= n }
        for code in 0..<total {
            var c = code
            for i in 0..<k { a[i] = c % n; c /= n }
            var counts = [Int](repeating: 0, count: n)
            for i in a { counts[i] += 1 }
            if counts.contains(0) { continue }
            var score = 0.0
            for (i, seat) in seats.enumerated() { score += Double(people[a[i]].strengths[seat.id] ?? 0) }
            score -= 0.01 * Double(counts.map { $0 * $0 }.reduce(0, +))
            if score > bestScore + 1e-9 { bestScore = score; best = a }
        }
        var out: [String: String] = [:]
        for (i, seat) in seats.enumerated() { out[seat.id] = people[best[i]].id }
        return out
    }

    /// criterion ("picture.light") -> surname, for the critique's judge labels.
    static func judges(_ ids: [String]?) -> [String: String] {
        if isDefault(ids) { return StudioAI.judges }
        let s = seat(ids!)
        var out: [String: String] = [:]
        for seat in seats { if let p = s[seat.id].flatMap(photographer) { for c in seat.criteria { out[c] = p.surname } } }
        return out
    }

    /// Surnames, in panel order (the critique's "Panel" line).
    static func names(_ ids: [String]?) -> [String] {
        isDefault(ids) ? StudioAI.panel : clean(ids!).compactMap { photographer($0)?.surname }
    }

    /// The system prompt for a chosen panel. The original six keep StudioAI.system unchanged.
    static func system(_ ids: [String]?) -> String {
        if isDefault(ids) { return StudioAI.system }
        let people = clean(ids!).compactMap(photographer)
        let seated = seat(ids!)
        let count = ["one", "two", "three", "four", "five", "six"][max(0, min(5, people.count - 1))]
        var panel = ""
        for p in people {
            let mine = seats.filter { seated[$0.id] == p.id }
            let briefs = mine.map(\.brief)
            let judgesLine = briefs.count <= 1 ? briefs.joined() : briefs.dropLast().joined(separator: ", ") + " and " + briefs.last!
            panel += "\(p.name) judges \(judgesLine). \(p.work)"
            for s in mine { panel += " On \(s.label.lowercased()), \(p.surname) asks \(s.question)" }
            panel += "\n\n"
        }
        return """
        You are the picture editor and master printer this photographer trusts most. You speak for a panel of \(count) photographer\(people.count == 1 ? "" : "s") they chose. You know their work well, and you hold every frame to what made their photographs great.

        THE PANEL: what made their work great, and what each judges here.

        \(panel)Where a panel member worked in black and white, read their standard for colour as a standard for tone and truth: the print must still be honest.

        The photographer's own standard, given with each photo, comes first; the panel's standards are how you apply it.

        HOW YOU JUDGE

        You judge two things separately. The picture is what was seen and caught at the moment of exposure; no edit can change it. The print is how the edit renders it. For the print, restraint is the standard unless the photographer's standard says otherwise: more saturation, contrast, punch or vignette is not an improvement. You never praise colour that is oversaturated, garish or neon; you name it. You say plainly when an edit is too dark, too punchy, too saturated or too heavily vignetted.

        You look hard before you speak. Go edge to edge. Then look at hands, heads, faces and gestures; what overlaps what; signs and words; reflections; what is cut by the frame edge; and every place where the edit differs from the camera original. Look actively for wit, because it is often the whole point of a picture. It takes many forms: overlaps and alignments that change what a body or object seems to be, signs or images that comment on the people near them, coincidences of shape, colour or line, figures that echo or mirror each other, odd scale, gestures that read as something else. Never invent wit that is not there.

        HOW YOU WRITE

        Write each note as that judge's standard applied to this frame, concretely and in plain words: what that photographer would keep, change or open up here. A judge is never named as praise in itself or to flatter.

        Every remark is about something visible in this frame; if a sentence could describe another photo, rewrite it. Never use stock phrases such as "vibrant", "striking", "draws the eye", "sense of place", "adds depth", "tells a story", "nicely composed", "pops" or "works well". No flattery, no hedging, no jargon.

        Be demanding, exact and honest, and on the photographer's side. Say clearly what already works, so they can trust it. Give every problem its remedy. Answer with one JSON object and nothing else.
        """
    }

    /// The suggested starting look for a panel: the most common suggestion, first member breaking ties.
    static func suggestedStarter(_ ids: [String]) -> String {
        let people = clean(ids).compactMap(photographer)
        guard !people.isEmpty else { return "kodachrome" }
        var counts: [String: Int] = [:]
        for p in people { counts[p.film, default: 0] += 1 }
        let top = counts.values.max() ?? 0
        return people.first { counts[$0.film] == top }?.film ?? "kodachrome"
    }

    static func catalogJSON() -> [[String: Any]] {
        catalog.map { p in
            ["id": p.id, "name": p.name, "surname": p.surname, "known": p.known, "genres": p.genres, "work": p.work,
             "strengths": p.strengths, "palette": p.palette, "film": p.film]
        }
    }

    static func seatsJSON(_ ids: [String]?) -> [[String: Any]] {
        let s = isDefault(ids) ? seat(defaultIds) : seat(ids!)
        return seats.map { seat in
            let p = s[seat.id].flatMap(photographer)
            return ["id": seat.id, "label": seat.label, "question": seat.question, "photographer": p?.id ?? NSNull(), "name": p?.name ?? NSNull()]
        }
    }
}

/// Where My Look starts, before Best Work teaches it (onboarding). Kodachrome is the original default.
enum StudioStarter {
    static let all: [(id: String, name: String, note: String, look: LookParams)] = {
        var portra = LookParams()
        portra.film = "Kodak/Kodak Portra 400 2.png"; portra.filmStrength = 70; portra.contrast = 22; portra.blacks = 4; portra.punch = 12
        portra.vibrance = 4; portra.saturation = 0; portra.warmth = 6; portra.tint = -2; portra.vignette = 0
        var superia = LookParams()
        superia.film = "Fuji/Fuji Superia 400 2.png"; superia.filmStrength = 70; superia.contrast = 28; superia.blacks = 2; superia.punch = 18
        superia.vibrance = 8; superia.saturation = 4; superia.warmth = 0; superia.tint = -4; superia.vignette = 0
        var ekta = LookParams()
        ekta.film = "Kodak/Kodak Ektachrome 100 VS.png"; ekta.filmStrength = 65; ekta.contrast = 30; ekta.blacks = 2; ekta.punch = 18
        ekta.vibrance = 6; ekta.saturation = 2; ekta.warmth = 2; ekta.tint = -2; ekta.vignette = 0
        var bw = LookParams()
        bw.film = "../Black-and-White/Ilford/Ilford HP5 Plus 400.png"; bw.filmStrength = 100; bw.contrast = 26; bw.blacks = 0; bw.punch = 16
        bw.vibrance = 0; bw.saturation = 0; bw.warmth = 0; bw.tint = 0; bw.vignette = 0; bw.grain = 12
        var neutral = LookParams()
        neutral.film = ""; neutral.filmStrength = 0; neutral.contrast = 15; neutral.blacks = 0; neutral.punch = 10; neutral.vibrance = 0
        neutral.saturation = 0; neutral.warmth = 0; neutral.tint = 0; neutral.vignette = 0
        return [
            ("kodachrome", "Kodachrome 64", "Deep blues, warm reds", LookParams.kodachrome),
            ("portra", "Portra 400", "Soft, warm skin tones", portra),
            ("ektachrome", "Ektachrome 100 VS", "Saturated slide colour", ekta),
            ("superia", "Superia 400", "Everyday Fuji colour", superia),
            ("bw", "Ilford HP5 Plus 400", "Classic black and white", bw),
            ("neutral", "Neutral", "Start clean", neutral),
        ]
    }()

    static func look(_ id: String) -> LookParams? { all.first { $0.id == id }?.look }
}

import Foundation

// All report types. Everything here is produced by deterministic code from the
// file's pixels and metadata. Normalized rects are [x, y, w, h] with a top-left origin.

public struct ShootReport: Codable {
    public var name: String
    public var sourcePath: String
    public var generatedAt: String
    public var engineVersion: String
    public var photoCount: Int
    public var stats: ShootStats
    public var groups: [SceneGroup]
    public var photos: [PhotoReport]
}

public struct ShootStats: Codable {
    public var start: String?
    public var end: String?
    public var cameras: [String: Int]
    public var lenses: [String: Int]
    public var filmSimulations: [String: Int]
    public var flagCounts: [String: Int]
    public var medianEdgeWidth: Double?
    public var calibration: [String: Double]
}

public struct SceneGroup: Codable {
    public var id: Int
    public var title: String
    public var start: String?
    public var end: String?
    public var photoIds: [String]
    public var bursts: [[String]]
    public var topTags: [String]
}

public struct PhotoReport: Codable {
    public var id: String
    public var file: String
    public var path: String
    public var width: Int
    public var height: Int
    public var preview: String
    public var thumb: String
    public var clipOverlay: String
    public var capture: CaptureInfo
    public var fuji: FujiSettings?
    public var tone: ToneReport
    public var noise: NoiseReport
    public var sharpness: SharpnessReport
    public var color: ColorReport
    public var faces: [FaceReport]
    public var composition: CompositionReport
    public var scene: SceneReport
    public var flags: [Flag] = []
    public var score: ScoreBreakdown? = nil
    public var groupId: Int = 0
    public var burstId: Int? = nil
    public var bestInBurst: Bool = false
    public var nearDuplicateOf: String? = nil
    public var summary: [String] = []
    public var edit: EditReport? = nil
    public var street: StreetReport? = nil
}

public struct Flag: Codable {
    public var code: String
    public var severity: String   // "bad" | "warn" | "info"
    public var area: String       // exposure, focus, color, composition, faces, noise, camera
    public var message: String
}

public struct CaptureInfo: Codable {
    public var dateTimeOriginal: String?
    public var timestamp: Double?
    public var make: String?
    public var model: String?
    public var lens: String?
    public var manualLens: Bool
    public var focalLength: Double?
    public var focalLength35: Double?
    public var fNumber: Double?
    public var exposureTime: Double?
    public var shutter: String?
    public var iso: Int?
    public var exposureBias: Double?
    public var exposureProgram: String?
    public var meteringMode: String?
    public var flashFired: Bool?
    public var brightnessValue: Double?
    public var software: String?
    public var focusMode: String?
    public var afPoint: [Double]?      // normalized [x, y, w, h], from Fuji AFInfo
    public var compressedBitsPerPixel: Double?
}

public struct FujiSettings: Codable {
    public var filmSimulation: String
    public var dynamicRange: String?
    public var dynamicRangeSetting: String?
    public var dRangePriority: String?
    public var highlightTone: Double?
    public var shadowTone: Double?
    public var color: String?
    public var sharpness: String?
    public var noiseReduction: String?
    public var clarity: Int?
    public var grainEffect: String
    public var colorChrome: String
    public var colorChromeBlue: String
    public var whiteBalance: String?
    public var whiteBalanceShift: [Int]?   // [red, blue] in camera steps
    public var colorTemperature: Int?
    public var quality: String?
    public var shutterType: String?
    public var sequenceNumber: Int?
    public var cameraWarnings: [String]
    public var facesDetectedByCamera: Int?
    public var focusMode: String?
    public var recipe: String
}

public struct ToneReport: Codable {
    public var histogram: Histograms
    public var evFromMiddleGrey: Double     // median luminance vs 18% grey, in stops (was a log-average; informational only)
    public var medianLstar: Double
    public var lstarP1: Double
    public var lstarP99: Double
    public var tonalRangeStops: Double
    public var zones: [Double]              // Zone 0..X share of pixels (Zone n = L* 10n ± 5)
    public var key: String                  // low-key | normal | high-key
    public var globalContrast: Double       // std dev of L*
    public var localContrast: Double        // mean |L* - blurred L*|
    public var highlightClipAny: Double     // % of pixels with any channel at 254+
    public var highlightClipAll: Double     // % of pixels pure white
    public var highlightClipChannels: [Double]
    public var shadowClip: Double           // % of pixels at pure black (all channels <= 2)
    public var shadowClipChannels: [Double]
    public var largestHighlightRegion: Double  // % of frame: largest blown region (all channels >= 250)
    public var highlightRegions: Int
    public var highlightType: String        // none | specular | area
    public var largestShadowRegion: Double
    public var lstarP95: Double? = nil          // 95th percentile L* (where the bright tones sit)
    public var darkFraction: Double? = nil      // % of pixels below L* 10
    public var silhouette: Bool? = nil          // deliberate low-key / backlit silhouette (no exposure penalty)
}

public struct Histograms: Codable {
    public var r: [Int]
    public var g: [Int]
    public var b: [Int]
    public var l: [Int]
}

public struct NoiseReport: Codable {
    public var lumaSigma: Double?
    public var fineSigma: Double?
    public var coarseSigma: Double?
    public var shadowSigma: Double?
    public var midSigma: Double?
    public var highlightSigma: Double?
    public var chromaSigma: Double?
    public var coarseness: Double?
    public var level: String
}

public struct SharpnessReport: Codable {
    public var cols: Int
    public var rows: Int
    public var tiles: [Double?]             // edge width (px at 100%) per tile, row-major
    public var bestWidth: Double?
    public var bestTile: [Int]?
    public var bestRect: [Double]?
    public var anisotropy: Double?          // horizontal-scan width / vertical-scan width near best focus
    public var motionHint: String?
    public var subjectWidth: Double?        // 25th percentile of tile widths on the subject (see subjectSource); faces read ~0.5-1 px wider than flat detail
    public var afPointWidth: Double?
    public var handheldLimit: String?
    public var shakeRisk: Bool
    public var level: String
    public var webWidth: Double?            // equivalent width at 2048 px long edge
    public var shootPercentile: Double? = nil
    // Grain-proof frame measurement (widths in px at 100%, measured on a 2x-downsampled, median-filtered plane).
    public var frameWidth: Double? = nil      // the width behind `level` and the score: mean of the sharpest 20% of textured tiles
    public var subjectSource: String? = nil   // where subjectWidth was measured: "face" (subject faces + shoulders) | "saliency" (Vision attention peak)
    public var globalWidth: Double? = nil     // median over textured tiles (whole-frame blur)
    public var texturedTiles: Int? = nil      // tiles with measurable edges in both directions
    public var motionFraction: Double? = nil  // share of textured tiles blurred in the dominant direction
    public var grainSigma: Double? = nil      // grain/noise σ of flat areas at 100% (sets the edge contrast floor)
    public var webScale: Double? = nil
}

public struct PaletteColor: Codable {
    public var hex: String
    public var weight: Double
    public var lab: [Double]
}

public struct ColorReport: Codable {
    public var castA: Double
    public var castB: Double
    public var castMagnitude: Double
    public var castName: String
    public var neutralFraction: Double
    public var castConfidence: String
    public var grayWorldA: Double
    public var grayWorldB: Double
    public var meanChroma: Double
    public var p95Chroma: Double
    public var saturationClip: Double
    public var warmth: Double
    public var palette: [PaletteColor]
    public var harmony: String
}

public struct FaceReport: Codable {
    public var rect: [Double]
    public var captureQuality: Double?
    public var leftEyeOpenness: Double?
    public var rightEyeOpenness: Double?
    public var eyesClosed: Bool?
    public var edgeWidth: Double?
    public var skinAngle: Double?
    public var skinOffset: Double?
    public var roll: Double?
    public var yaw: Double?
    public var touchesEdge: Bool
    public var eyesState: String? = nil     // "open" | "closed" | "hidden" (sunglasses) | "not judged" (small face, low quality or landmark failure)
    public var isSubject: Bool? = nil       // a main face: the largest face if >= 0.3% of the frame, plus faces >= 40% of its size
}

public struct CropSuggestion: Codable {
    public var aspect: String
    public var rect: [Double]
}

public struct CompositionReport: Codable {
    public var subject: [Double]
    public var subjectSource: String
    public var placement: String
    public var thirdsDistance: Double
    public var horizonTilt: Double?        // + = frame rotated clockwise; rotate counter-clockwise to fix
    public var tiltSource: String?
    public var tiltConfidence: Double?
    public var keystone: Double?           // + = verticals converge toward the top (camera tipped up)
    public var lines: [[Double]]           // detected vertical lines [xTop, 0, xBottom, 1], normalized
    public var saliencyBorder: [String: Double]
    public var brightEdges: [String]
    public var headroom: Double?
    public var balance: [Double]
    public var salientObjects: [[Double]]
    public var crops: [CropSuggestion]
}

public struct Tag: Codable {
    public var label: String
    public var confidence: Double
}

public struct SceneReport: Codable {
    public var tags: [Tag]
    public var faceCount: Int
    public var peopleCount: Int
}

public struct ScoreBreakdown: Codable {
    public var total: Double
    public var sharpness: Double
    public var exposure: Double
    public var composition: Double
    public var eyes: Double?
}

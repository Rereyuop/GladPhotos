enum PhotoGridDisplayMode {
    case square
    case originalRatio

    var title: String {
        switch self {
        case .square:
            return "正方形"
        case .originalRatio:
            return "原比例"
        }
    }
}

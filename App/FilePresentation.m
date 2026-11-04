#import "FilePresentation.h"

BOOL LCFileColumnsAreWide(CGFloat width, UITraitCollection *traits) {
    return width >= 650 && !UIContentSizeCategoryIsAccessibilityCategory(traits.preferredContentSizeCategory);
}

static UILabel *FileLabel(NSString *text, UIFontTextStyle style) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    label.lineBreakMode = NSLineBreakByCharWrapping;
    return label;
}

UIStackView *LCFileColumns(NSArray<UIView *> *views, BOOL wide) {
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    if (wide) {
        [views[1].widthAnchor constraintEqualToConstant:82].active = YES;
        [views[2].widthAnchor constraintEqualToConstant:90].active = YES;
        [views[3].widthAnchor constraintEqualToConstant:142].active = YES;
    } else {
        stack.distribution = UIStackViewDistributionFillEqually;
    }
    return stack;
}

UIView *LCFileEntry(NSDictionary *item, NSString *extra, BOOL icons, BOOL wide, UITraitCollection *traits) {
    BOOL folder = [item[@"directory"] boolValue];
    BOOL video = [item[@"video"] boolValue];
    BOOL subtitle = [item[@"subtitle"] boolValue];
    NSString *ext = [item[@"name"] pathExtension].uppercaseString;
    NSString *type = folder ? @"文件夹" : (ext.length ? [ext stringByAppendingString:subtitle ? @" 字幕" : (video ? @" 视频" : @" 文件")] : @"文件");
    NSString *size = folder ? @"—" : [NSByteCountFormatter stringFromByteCount:[item[@"size"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile];
    NSString *date = [item[@"modified"] isKindOfClass:NSNumber.class] ? [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[item[@"modified"] doubleValue]] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle] : @"—";
    UIImageView *image = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:folder ? @"folder.fill" : (subtitle ? @"captions.bubble" : (video ? @"play.rectangle.fill" : @"doc.fill"))]];
    image.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:icons ? 48 : 24 weight:UIImageSymbolWeightRegular];
    image.contentMode = UIViewContentModeScaleAspectFit;
    image.tintColor = folder ? UIColor.systemYellowColor : (subtitle ? UIColor.secondaryLabelColor : UIColor.systemTealColor);
    [image.widthAnchor constraintEqualToConstant:icons ? 64 : 30].active = YES;
    [image.heightAnchor constraintEqualToConstant:icons ? 60 : 32].active = YES;
    UILabel *name = FileLabel(item[@"name"], UIFontTextStyleBody);
    name.accessibilityIdentifier = @"file-name";
    UILabel *detail = FileLabel(extra, UIFontTextStyleCaption1);
    detail.textColor = UIColor.secondaryLabelColor;
    detail.hidden = !extra.length;
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[name, detail]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 4;
    UIStackView *identity = [[UIStackView alloc] initWithArrangedSubviews:@[image, text]];
    identity.axis = icons ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    identity.alignment = icons ? UIStackViewAlignmentCenter : UIStackViewAlignmentTop;
    identity.spacing = icons ? 8 : 10;
    if (icons) {
        name.textAlignment = NSTextAlignmentCenter;
        detail.textAlignment = NSTextAlignmentCenter;
        UILabel *caption = FileLabel(folder ? type : [NSString stringWithFormat:@"%@ · %@", ext, size], UIFontTextStyleCaption1);
        caption.textColor = UIColor.secondaryLabelColor;
        caption.textAlignment = NSTextAlignmentCenter;
        [text insertArrangedSubview:caption atIndex:1];
        [text.widthAnchor constraintEqualToAnchor:identity.widthAnchor].active = YES;
        return identity;
    }
    UILabel *sizeLabel = FileLabel(size, UIFontTextStyleCaption1);
    UILabel *typeLabel = FileLabel(type, UIFontTextStyleCaption1);
    UILabel *dateLabel = FileLabel(date, UIFontTextStyleCaption1);
    for (UILabel *label in @[sizeLabel, typeLabel, dateLabel]) label.textColor = UIColor.secondaryLabelColor;
    sizeLabel.accessibilityLabel = [@"大小 " stringByAppendingString:size];
    typeLabel.accessibilityLabel = [@"类型 " stringByAppendingString:type];
    dateLabel.accessibilityLabel = [@"修改时间 " stringByAppendingString:date];
    if (wide) return LCFileColumns(@[identity, sizeLabel, typeLabel, dateLabel], YES);
    UIStackView *metadata = LCFileColumns(@[sizeLabel, typeLabel, dateLabel], NO);
    if (UIContentSizeCategoryIsAccessibilityCategory(traits.preferredContentSizeCategory)) {
        metadata.axis = UILayoutConstraintAxisVertical;
        metadata.alignment = UIStackViewAlignmentLeading;
        metadata.distribution = UIStackViewDistributionFill;
        sizeLabel.text = [@"大小：" stringByAppendingString:size];
        typeLabel.text = [@"类型：" stringByAppendingString:type];
        dateLabel.text = [@"修改：" stringByAppendingString:date];
    }
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[identity, metadata]];
    row.axis = UILayoutConstraintAxisVertical;
    row.spacing = 7;
    return row;
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/song.dart';
import '../services/encoding_sanitizer.dart';

class SongAlbumArt extends StatelessWidget {
  final Song song;
  final double? width;
  final double? height;
  final double borderRadius;
  final BoxFit fit;

  const SongAlbumArt({
    super.key,
    required this.song,
    this.width,
    this.height,
    this.borderRadius = 12.0,
    this.fit = BoxFit.cover,
  });

  static const List<String> _defaultThumbnails = [
    'https://images.unsplash.com/photo-1511671782779-c97d3d27a1d4?w=500&q=80',
    'https://images.unsplash.com/photo-1514525253161-7a46d19cd819?w=500&q=80',
    'https://images.unsplash.com/photo-1470225620780-dba8ba36b745?w=500&q=80',
    'https://images.unsplash.com/photo-1459749411175-04bf5292ceea?w=500&q=80',
    'https://images.unsplash.com/photo-1493225457124-a3eb161ffa5f?w=500&q=80',
    'https://images.unsplash.com/photo-1487180142328-0c4e37023af5?w=500&q=80',
    'https://images.unsplash.com/photo-1506157786151-b8491531f063?w=500&q=80',
    'https://images.unsplash.com/photo-1525994886773-080587e161c2?w=500&q=80',
    'https://images.unsplash.com/photo-1518609878373-06d740f60d8b?w=500&q=80',
    'https://images.unsplash.com/photo-1508700115892-45ecd05ae2ad?w=500&q=80',
  ];

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;

    // 1. Sanitize the thumbnail URL with protocol & quality upgrades
    final rawUrl = song.thumbnailUrl.trim().isNotEmpty
        ? song.thumbnailUrl.trim()
        : song.highResThumbnailUrl.trim();

    final sanitizedUrl = EncodingSanitizer.sanitizeThumbnailUrl(
      rawUrl,
      videoId: song.videoId,
    );

    // 2. Check for empty or placeholder thumbnails
    final bool noThumb = sanitizedUrl.isEmpty ||
        sanitizedUrl.startsWith('placeholder_');

    if (noThumb && (song.isLocalFile || song.filePath != null)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: _buildAbstractPlaceholder(song.videoId, primaryColor),
      );
    }

    // 3. Base64 Data URI or raw Base64 payload (embedded in tags / APIs)
    if (_isBase64Image(sanitizedUrl)) {
      final bytes = _decodeBase64Bytes(sanitizedUrl);
      if (bytes != null && bytes.isNotEmpty) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: Image.memory(
            bytes,
            fit: fit,
            width: width,
            height: height,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded) return child;
              return AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                child: child,
              );
            },
            errorBuilder: (context, error, stackTrace) =>
                _buildAbstractPlaceholder(song.videoId, primaryColor),
          ),
        );
      }
    }

    final String url;
    if (noThumb) {
      final int hash = song.videoId.hashCode.abs();
      url = _defaultThumbnails[hash % _defaultThumbnails.length];
    } else {
      url = sanitizedUrl;
    }

    final isHttp = url.startsWith('http://') || url.startsWith('https://');
    
    // Resolve local file path (handles file:// URIs and standard paths)
    String? localFilePath;
    if (!isHttp && url.isNotEmpty) {
      if (url.startsWith('file://')) {
        try {
          localFilePath = Uri.parse(url).toFilePath();
        } catch (_) {
          localFilePath = url.replaceFirst('file://', '');
        }
      } else if (url.startsWith('/') || url.contains(r':\') || url.contains(':/')) {
        localFilePath = url;
      }
    }

    final bool isLocalValid = localFilePath != null &&
        File(localFilePath).existsSync() &&
        File(localFilePath).lengthSync() > 32;

    Widget child;

    if (isHttp) {
      child = CachedNetworkImage(
        imageUrl: url,
        fit: fit,
        width: width,
        height: height,
        fadeInDuration: const Duration(milliseconds: 350),
        fadeInCurve: Curves.easeOut,
        fadeOutDuration: const Duration(milliseconds: 200),
        placeholder: (context, _) => Container(
          width: width,
          height: height,
          color: Colors.white.withValues(alpha: 0.05),
          child: const Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(Colors.white30),
              ),
            ),
          ),
        ),
        errorWidget: (context, url, error) {
          // Secondary fallback: if primary failed and high-res or YouTube standard exists
          final fallbackUrl = _getNetworkFallbackUrl(url, song);
          if (fallbackUrl != null && fallbackUrl != url) {
            return CachedNetworkImage(
              imageUrl: fallbackUrl,
              fit: fit,
              width: width,
              height: height,
              fadeInDuration: const Duration(milliseconds: 250),
              errorWidget: (context, fallbackErrUrl, fallbackErr) =>
                  _buildAbstractPlaceholder(song.videoId, primaryColor),
            );
          }
          return _buildAbstractPlaceholder(song.videoId, primaryColor);
        },
      );
    } else if (isLocalValid) {
      child = Image.file(
        File(localFilePath),
        fit: fit,
        width: width,
        height: height,
        frameBuilder: (context, image, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded) return image;
          return AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOut,
            child: image,
          );
        },
        errorBuilder: (context, error, stackTrace) =>
            _buildAbstractPlaceholder(song.videoId, primaryColor),
      );
    } else {
      child = _buildAbstractPlaceholder(song.videoId, primaryColor);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: child,
    );
  }

  /// Get fallback network image when primary fails (e.g. YouTube maxresdefault 404)
  String? _getNetworkFallbackUrl(String failedUrl, Song song) {
    if (song.videoId.isNotEmpty &&
        !song.videoId.startsWith('jiosaavn_') &&
        !song.videoId.startsWith('local_') &&
        (failedUrl.contains('maxresdefault') || failedUrl.contains('sddefault'))) {
      return 'https://i.ytimg.com/vi/${song.videoId}/hqdefault.jpg';
    }
    if (song.highResThumbnailUrl.isNotEmpty &&
        song.highResThumbnailUrl.startsWith('http') &&
        song.highResThumbnailUrl != failedUrl) {
      return EncodingSanitizer.sanitizeThumbnailUrl(song.highResThumbnailUrl);
    }
    return null;
  }

  bool _isBase64Image(String s) {
    return s.startsWith('data:image/') ||
        s.startsWith('/9j/') ||
        s.startsWith('iVBORw0KGgo') ||
        s.startsWith('R0lGOD') ||
        s.startsWith('UklGR');
  }

  Uint8List? _decodeBase64Bytes(String input) {
    try {
      String raw = input;
      if (raw.contains(',')) {
        raw = raw.split(',').last;
      }
      raw = raw.replaceAll(RegExp(r'\s+'), '');
      return base64Decode(base64.normalize(raw));
    } catch (_) {
      return null;
    }
  }

  Widget _buildAbstractPlaceholder(String seed, Color primaryColor) {
    final int hash = seed.hashCode.abs();
    final int index = hash % 3;

    return Container(
      width: width,
      height: height,
      color: const Color(0xFF0F0F1A),
      child: CustomPaint(
        painter: _AbstractArtPainter(index: index, primaryColor: primaryColor),
      ),
    );
  }
}

class _AbstractArtPainter extends CustomPainter {
  final int index;
  final Color primaryColor;

  _AbstractArtPainter({required this.index, required this.primaryColor});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final paint = Paint()..isAntiAlias = true;

    if (index == 0) {
      // DESIGN 1: Neon Synthwave (Magenta, Purple, Cyan)
      final gradient = const LinearGradient(
        colors: [
          Color(0xFFD80073),
          Color(0xFF6A00FF),
          Color(0xFF00D2FF),
        ],
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
      );
      paint.shader = gradient.createShader(rect);
      canvas.drawRect(rect, paint);

      // Central glowing sun
      final sunPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(
        Offset(size.width * 0.5, size.height * 0.5),
        size.width * 0.28,
        sunPaint,
      );

      // Music note icon
      final textPainter = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(Icons.music_note_rounded.codePoint),
          style: TextStyle(
            fontSize: size.width * 0.35,
            fontFamily: Icons.music_note_rounded.fontFamily,
            package: Icons.music_note_rounded.fontPackage,
            color: Colors.white.withValues(alpha: 0.7),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        Offset(
          (size.width - textPainter.width) / 2,
          (size.height - textPainter.height) / 2,
        ),
      );
    } else if (index == 1) {
      // DESIGN 2: Deep Cosmic Aurora (Emerald, Sapphire, Deep Navy)
      final gradient = const LinearGradient(
        colors: [
          Color(0xFF00C9FF),
          Color(0xFF92FE9D),
          Color(0xFF00223E),
        ],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
      paint.shader = gradient.createShader(rect);
      canvas.drawRect(rect, paint);

      final orbPaint = Paint()
        ..color = primaryColor.withValues(alpha: 0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
      canvas.drawCircle(
        Offset(size.width * 0.65, size.height * 0.35),
        size.width * 0.3,
        orbPaint,
      );

      final textPainter = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(Icons.graphic_eq_rounded.codePoint),
          style: TextStyle(
            fontSize: size.width * 0.32,
            fontFamily: Icons.graphic_eq_rounded.fontFamily,
            package: Icons.graphic_eq_rounded.fontPackage,
            color: Colors.white.withValues(alpha: 0.75),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        Offset(
          (size.width - textPainter.width) / 2,
          (size.height - textPainter.height) / 2,
        ),
      );
    } else {
      // DESIGN 3: Electric Sunset (Amber, Crimson, Deep Violet)
      final gradient = LinearGradient(
        colors: [
          const Color(0xFFFF512F),
          const Color(0xFFDD2476),
          primaryColor.withValues(alpha: 0.8),
        ],
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
      );
      paint.shader = gradient.createShader(rect);
      canvas.drawRect(rect, paint);

      final textPainter = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(Icons.headphones_rounded.codePoint),
          style: TextStyle(
            fontSize: size.width * 0.32,
            fontFamily: Icons.headphones_rounded.fontFamily,
            package: Icons.headphones_rounded.fontPackage,
            color: Colors.white.withValues(alpha: 0.75),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        Offset(
          (size.width - textPainter.width) / 2,
          (size.height - textPainter.height) / 2,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AbstractArtPainter old) =>
      old.index != index || old.primaryColor != primaryColor;
}

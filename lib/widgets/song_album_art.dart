import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:math' as math;
import '../models/song.dart';

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

    // Resolve empty or placeholder thumbnails:
    // - LOCAL files: use the deterministic abstract art (the file's embedded
    //   cover, when present, is already in thumbnailUrl via LocalMetadataService;
    //   a random internet photo would be wrong/misleading for a user's own file).
    // - streamed songs: fall back to the stable Unsplash covers as before.
    final bool noThumb = song.thumbnailUrl.trim().isEmpty ||
        song.thumbnailUrl.trim().startsWith('placeholder_');
    if (noThumb && (song.isLocalFile || song.filePath != null)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: _buildAbstractPlaceholder(song.videoId, primaryColor),
      );
    }

    final String url;
    if (noThumb) {
      final int hash = song.videoId.hashCode.abs();
      url = _defaultThumbnails[hash % _defaultThumbnails.length];
    } else {
      url = song.thumbnailUrl;
    }

    final isHttp = url.startsWith('http://') || url.startsWith('https://');
    final isLocalFile = url.isNotEmpty && !isHttp && (url.startsWith('/') || url.contains(':\\') || url.contains(':/'));

    Widget child;

    if (isHttp) {
      child = CachedNetworkImage(
        imageUrl: url,
        fit: fit,
        width: width,
        height: height,
        // Gentle cross-fade from placeholder to the resolved cover instead of
        // a hard pop-in.
        fadeInDuration: const Duration(milliseconds: 400),
        fadeInCurve: Curves.easeOut,
        fadeOutDuration: const Duration(milliseconds: 200),
        placeholder: (context, url) => Container(
          color: Colors.white.withValues(alpha: 0.05),
          child: const Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white30)),
            ),
          ),
        ),
        errorWidget: (context, url, error) => _buildAbstractPlaceholder(song.videoId, primaryColor),
      );
    } else if (isLocalFile && File(url).existsSync()) {
      // Fade local images in as they decode.
      child = Image.file(
        File(url),
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
      );
    } else {
      child = _buildAbstractPlaceholder(song.videoId, primaryColor);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: child,
    );
  }

  Widget _buildAbstractPlaceholder(String seed, Color primaryColor) {
    // Generate a stable hash index (0, 1, or 2) based on the song's video ID/path
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
      // DESIGN 1: Neon Synthwave (Magenta, Purple, Indigo, Cyan)
      final gradient = LinearGradient(
        colors: const [
          Color(0xFFD80073),
          Color(0xFF6A00FF),
          Color(0xFF00D2FF),
        ],
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
      );
      paint.shader = gradient.createShader(rect);
      canvas.drawRect(rect, paint);

      // Glassmorphic central sun
      final sunPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.15)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      canvas.drawCircle(Offset(size.width * 0.5, size.height * 0.5), size.width * 0.28, sunPaint);

      // Neon cyan gridlines
      final gridPaint = Paint()
        ..color = const Color(0xFF00FFCC).withValues(alpha: 0.25)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke;

      final path = Path();
      // Horizontal lines converging
      for (int i = 0; i <= 6; i++) {
        final double y = size.height * 0.4 + (size.height * 0.6 * math.pow(i / 6, 2));
        path.moveTo(0, y);
        path.lineTo(size.width, y);
      }
      // Vanishing perspective vertical lines
      final Offset vanishPoint = Offset(size.width * 0.5, size.height * 0.4);
      for (int i = -3; i <= 3; i++) {
        final double xEnd = size.width * 0.5 + (i * size.width * 0.2);
        path.moveTo(vanishPoint.dx, vanishPoint.dy);
        path.lineTo(xEnd, size.height);
      }
      canvas.drawPath(path, gridPaint);

    } else if (index == 1) {
      // DESIGN 2: Sunset Lofi (Amber, Crimson, Dark Violet)
      final gradient = RadialGradient(
        colors: const [
          Color(0xFFFF9E00),
          Color(0xFFFF0055),
          Color(0xFF3C096C),
        ],
        radius: 1.2,
        center: Alignment.topCenter,
      );
      paint.shader = gradient.createShader(rect);
      canvas.drawRect(rect, paint);

      // Glowing Crescent Moon
      final moonPaint = Paint()
        ..color = const Color(0xFFFFE57F).withValues(alpha: 0.85);
      
      final moonPath = Path()
        ..addOval(Rect.fromCircle(center: Offset(size.width * 0.52, size.height * 0.45), radius: size.width * 0.22));
      final shadowPath = Path()
        ..addOval(Rect.fromCircle(center: Offset(size.width * 0.44, size.height * 0.40), radius: size.width * 0.22));
      
      final crescentPath = Path.combine(PathOperation.difference, moonPath, shadowPath);
      canvas.drawPath(crescentPath, moonPaint);

      // Retro waves/sun bars
      final barPaint = Paint()..color = const Color(0xFF1E0B36).withValues(alpha: 0.4);
      for (int i = 0; i < 4; i++) {
        final double y = size.height * 0.65 + i * (size.height * 0.08);
        final double height = size.height * 0.03 + i * (size.height * 0.005);
        canvas.drawRect(Rect.fromLTWH(0, y, size.width, height), barPaint);
      }

    } else {
      // DESIGN 3: Cyberpunk Techno (Indigo, Cyan, Toxic Lime)
      final gradient = LinearGradient(
        colors: const [
          Color(0xFF1D2A44),
          Color(0xFF00F5FF),
          Color(0xFF39FF14),
        ],
        begin: Alignment.bottomRight,
        end: Alignment.topLeft,
      );
      paint.shader = gradient.createShader(rect);
      canvas.drawRect(rect, paint);

      // Rotating techno squares
      final squarePaint = Paint()
        ..color = const Color(0xFF39FF14).withValues(alpha: 0.15)
        ..style = PaintingStyle.fill;
      
      final borderPaint = Paint()
        ..color = const Color(0xFF00F5FF).withValues(alpha: 0.6)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      canvas.save();
      canvas.translate(size.width * 0.5, size.height * 0.5);
      
      // Square 1
      canvas.rotate(math.pi / 6);
      canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: size.width * 0.4, height: size.width * 0.4), squarePaint);
      canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: size.width * 0.4, height: size.width * 0.4), borderPaint);

      // Square 2
      canvas.rotate(math.pi / 4);
      canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: size.width * 0.3, height: size.width * 0.3), borderPaint);

      canvas.restore();

      // Techno connection dots
      final dotsPaint = Paint()..color = Colors.white.withValues(alpha: 0.25);
      canvas.drawCircle(Offset(size.width * 0.2, size.height * 0.2), 3, dotsPaint);
      canvas.drawCircle(Offset(size.width * 0.8, size.height * 0.2), 4, dotsPaint);
      canvas.drawCircle(Offset(size.width * 0.15, size.height * 0.75), 3, dotsPaint);
      canvas.drawCircle(Offset(size.width * 0.75, size.height * 0.8), 5, dotsPaint);

      canvas.drawLine(
        Offset(size.width * 0.2, size.height * 0.2),
        Offset(size.width * 0.8, size.height * 0.2),
        Paint()..color = Colors.white.withValues(alpha: 0.08)..strokeWidth = 1.0,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AbstractArtPainter oldDelegate) =>
      oldDelegate.index != index || oldDelegate.primaryColor != primaryColor;
}

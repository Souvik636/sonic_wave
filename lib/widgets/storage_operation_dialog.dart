import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_colors.dart';

/// Storage operation mode chosen by user when organizing or moving songs into albums.
class StorageOperationChoice {
  final bool physicalMove;
  final bool isCopyMode;

  const StorageOperationChoice({
    required this.physicalMove,
    required this.isCopyMode,
  });

  /// Duplicate physical audio file into target album directory while preserving original.
  static const copy = StorageOperationChoice(physicalMove: true, isCopyMode: true);

  /// Physically move audio file on disk to destination album directory completely.
  static const move = StorageOperationChoice(physicalMove: true, isCopyMode: false);

  /// Reference/catalog song in app memory only without altering disk files.
  static const bookmark = StorageOperationChoice(physicalMove: false, isCopyMode: false);
}

/// Displays the interactive 3-card storage operation dialog.
Future<StorageOperationChoice?> showStorageOperationDialog(
  BuildContext context, {
  String title = 'Choose Storage Operation',
  String subtitle = 'How would you like to handle the file storage for this target album?',
}) async {
  final primaryColor = Theme.of(context).colorScheme.primary;

  return showDialog<StorageOperationChoice>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      contentPadding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: primaryColor.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.swap_horiz_rounded, color: primaryColor, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            subtitle,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12.5,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 18),

          // 1. Make a Copy Option Card
          _buildOptionCard(
            ctx,
            icon: Icons.copy_rounded,
            title: 'Make a Copy',
            subtitle: 'Duplicates file into target album directory while preserving original in place.',
            color: Colors.cyanAccent,
            onTap: () => Navigator.pop(ctx, StorageOperationChoice.copy),
          ),
          const SizedBox(height: 10),

          // 2. Permanently Move Option Card
          _buildOptionCard(
            ctx,
            icon: Icons.drive_file_move_rounded,
            title: 'Permanently Move',
            subtitle: 'Physically transfers original audio file on disk into target album folder.',
            color: primaryColor,
            onTap: () => Navigator.pop(ctx, StorageOperationChoice.move),
          ),
          const SizedBox(height: 10),

          // 3. In-App Bookmark Option Card
          _buildOptionCard(
            ctx,
            icon: Icons.bookmark_added_rounded,
            title: 'In-App Bookmark',
            subtitle: 'Organizes song in app memory only without moving or altering disk files.',
            color: Colors.purpleAccent,
            onTap: () => Navigator.pop(ctx, StorageOperationChoice.bookmark),
          ),
          const SizedBox(height: 8),

          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel', style: TextStyle(color: AppColors.textTertiary)),
            ),
          ),
        ],
      ),
    ),
  );
}

Widget _buildOptionCard(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String subtitle,
  required Color color,
  required VoidCallback onTap,
}) {
  return Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.25), width: 1),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 11,
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.arrow_forward_ios_rounded, color: color.withValues(alpha: 0.7), size: 14),
          ],
        ),
      ),
    ),
  );
}

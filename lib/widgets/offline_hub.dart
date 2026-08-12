import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../models/album.dart';
import '../providers/player_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_colors.dart';
import 'album_details_sheet.dart';
import 'song_tile.dart';
import 'app_toast.dart';

/// Ultra-Premium Offline Mode Hub
/// Displays offline downloads, scanned local storage, offline favorites, and user albums.
class OfflineHub extends StatefulWidget {
  const OfflineHub({super.key});

  @override
  State<OfflineHub> createState() => _OfflineHubState();
}

class _OfflineHubState extends State<OfflineHub> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _activeTab = 'All Offline';
  String _selectedFolder = 'All Folders';

  final List<String> _tabs = [
    'All Offline',
    '📥 Downloads',
    '📁 Local Storage',
    '❤️ Favorites',
    '📀 Albums',
  ];

  final List<String> _folderFilterOptions = [
    'All Folders',
    'Download',
    'Music',
    'WhatsApp',
    'Bluetooth',
    'DCIM',
  ];

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _showCreateAlbumDialog(BuildContext context, PlayerProvider playerProvider) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Create New Album Folder', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Album name (e.g. Chill Beats, Gym Focus)...',
            hintStyle: const TextStyle(color: AppColors.textTertiary, fontSize: 12),
            filled: true,
            fillColor: AppColors.surfaceVariant.withValues(alpha: 0.5),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                Navigator.pop(ctx);
                final album = await playerProvider.createAlbum(name);
                if (context.mounted) {
                  AppToast.show(context, 'Album "$name" created', type: ToastType.success);
                  AlbumDetailsSheet.show(context, album.id);
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playerProvider = Provider.of<PlayerProvider>(context);
    final settingsProvider = Provider.of<SettingsProvider>(context);

    final allOffline = playerProvider.localSongsMerged;
    final downloads = playerProvider.downloadedSongs;
    final favorites = playerProvider.favorites.where((s) => s.isLocalFile || downloads.any((d) => d.videoId == s.videoId)).toList();
    final albums = playerProvider.albums;

    // Filter songs based on active tab & search query
    List<Song> displaySongs = [];
    if (_activeTab == '📥 Downloads') {
      displaySongs = downloads;
    } else if (_activeTab == '📁 Local Storage') {
      displaySongs = allOffline.where((s) => s.id.startsWith('local_') || s.isLocalFile).toList();
      if (_selectedFolder != 'All Folders') {
        displaySongs = displaySongs.where((s) {
          final path = (s.filePath ?? s.videoId).toLowerCase();
          return path.contains(_selectedFolder.toLowerCase());
        }).toList();
      }
    } else if (_activeTab == '❤️ Favorites') {
      displaySongs = favorites;
    } else {
      displaySongs = allOffline;
    }

    if (_searchQuery.isNotEmpty) {
      displaySongs = displaySongs.where((s) {
        return s.title.toLowerCase().contains(_searchQuery) ||
            s.artist.toLowerCase().contains(_searchQuery) ||
            (s.albumFolderName ?? '').toLowerCase().contains(_searchQuery);
      }).toList();
    }

    final totalStorageBytes = allOffline.fold<int>(0, (sum, s) => sum + s.fileSizeInBytes);
    final totalMb = (totalStorageBytes / (1024 * 1024)).toStringAsFixed(1);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            // Glass Hero Header
            SliverToBoxAdapter(
              child: _buildOfflineHeroHeader(
                context,
                settingsProvider,
                playerProvider,
                allOffline,
                totalMb,
              ),
            ),

            // Search Bar & Filter Chips
            SliverToBoxAdapter(
              child: Column(
                children: [
                  // Search Bar
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                    child: TextField(
                      controller: _searchController,
                      style: GoogleFonts.inter(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Search offline tracks, artists, albums...',
                        hintStyle: GoogleFonts.inter(
                          color: AppColors.textTertiary.withValues(alpha: 0.6),
                          fontSize: 13,
                        ),
                        prefixIcon: const Icon(Icons.search_rounded, color: AppColors.textTertiary, size: 20),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.close_rounded, color: AppColors.textTertiary, size: 18),
                                onPressed: () => _searchController.clear(),
                              )
                            : null,
                        filled: true,
                        fillColor: AppColors.surfaceVariant.withValues(alpha: 0.5),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(
                            color: Theme.of(context).colorScheme.primary,
                            width: 1.5,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                    ),
                  ),

                  // Filter Chips Row
                  SizedBox(
                    height: 40,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _tabs.length,
                      itemBuilder: (context, idx) {
                        final tab = _tabs[idx];
                        final isSelected = _activeTab == tab;
                        final primaryColor = Theme.of(context).colorScheme.primary;

                        return GestureDetector(
                          onTap: () => setState(() => _activeTab = tab),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                              color: isSelected ? primaryColor : AppColors.surfaceVariant.withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: isSelected ? primaryColor : AppColors.glassBorder,
                                width: 1,
                              ),
                              boxShadow: isSelected
                                  ? [
                                      BoxShadow(
                                        color: primaryColor.withValues(alpha: 0.3),
                                        blurRadius: 10,
                                        spreadRadius: 1,
                                      ),
                                    ]
                                  : [],
                            ),
                            child: Text(
                              tab,
                              style: GoogleFonts.inter(
                                color: isSelected ? Colors.white : AppColors.textSecondary,
                                fontSize: 12.5,
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),

                  // Sub-Folder Filter Row (Only for Local Storage Tab)
                  if (_activeTab == '📁 Local Storage') ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 32,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        itemCount: _folderFilterOptions.length,
                        itemBuilder: (context, idx) {
                          final opt = _folderFilterOptions[idx];
                          final isSel = _selectedFolder == opt;
                          final primaryColor = Theme.of(context).colorScheme.primary;

                          return GestureDetector(
                            onTap: () => setState(() => _selectedFolder = opt),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              margin: const EdgeInsets.only(right: 6),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: isSel ? primaryColor.withValues(alpha: 0.2) : AppColors.surfaceVariant.withValues(alpha: 0.3),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isSel ? primaryColor.withValues(alpha: 0.6) : AppColors.glassBorder.withValues(alpha: 0.2),
                                ),
                              ),
                              child: Text(
                                opt,
                                style: TextStyle(
                                  color: isSel ? Colors.white : AppColors.textTertiary,
                                  fontSize: 11,
                                  fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],

                  const SizedBox(height: 14),
                ],
              ),
            ),

            // Content List / Albums Grid
            if (_activeTab == '📀 Albums') ...[
              _buildAlbumsGrid(context, playerProvider, albums),
            ] else if (displaySongs.isEmpty) ...[
              SliverFillRemaining(
                hasScrollBody: false,
                child: _buildEmptyState(context, playerProvider),
              ),
            ] else ...[
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final song = displaySongs[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: SongTile(
                        song: song,
                        index: index,
                        sourceTag: song.id.startsWith('local_') ? 'local' : 'downloaded',
                        onTap: () {
                          playerProvider.playPlaylist(displaySongs, startIndex: index);
                        },
                      ),
                    );
                  },
                  childCount: displaySongs.length,
                ),
              ),
            ],

            const SliverToBoxAdapter(
              child: SizedBox(height: 140),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOfflineHeroHeader(
    BuildContext context,
    SettingsProvider settingsProvider,
    PlayerProvider playerProvider,
    List<Song> allOffline,
    String totalMb,
  ) {
    final primary = Theme.of(context).colorScheme.primary;

    int mp3Count = 0;
    int m4aCount = 0;
    int flacCount = 0;
    int otherCount = 0;

    for (final s in allOffline) {
      final p = (s.filePath ?? s.videoId).toLowerCase();
      if (p.endsWith('.mp3')) {
        mp3Count++;
      } else if (p.endsWith('.m4a') || p.endsWith('.aac')) {
        m4aCount++;
      } else if (p.endsWith('.flac')) {
        flacCount++;
      } else {
        otherCount++;
      }
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            primary.withValues(alpha: 0.25),
            Colors.purpleAccent.withValues(alpha: 0.12),
            AppColors.surfaceVariant.withValues(alpha: 0.6),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: primary.withValues(alpha: 0.4),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: primary.withValues(alpha: 0.15),
            blurRadius: 24,
            spreadRadius: 2,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.amberAccent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.4), width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Colors.amberAccent,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(color: Colors.amberAccent, blurRadius: 6, spreadRadius: 1),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'OFFLINE MUSIC ENGINE',
                      style: GoogleFonts.outfit(
                        color: Colors.amberAccent,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),

              // Switch to Online Button
              GestureDetector(
                onTap: () {
                  settingsProvider.setOfflineModeOnly(false);
                  AppToast.show(
                    context,
                    'Switched to Online Mode',
                    type: ToastType.info,
                    icon: Icons.wifi_rounded,
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: primary.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: primary.withValues(alpha: 0.5), width: 1),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.wifi_rounded, color: primary, size: 14),
                      const SizedBox(width: 6),
                      Text(
                        'Go Online',
                        style: GoogleFonts.inter(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Title & Stats
          Text(
            'Offline Storage & Albums',
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${allOffline.length} Offline Tracks • $totalMb MB Storage Used',
            style: GoogleFonts.inter(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),

          const SizedBox(height: 12),

          // Audio Format Badges
          Wrap(
            spacing: 6,
            children: [
              _buildFormatBadge('MP3', mp3Count, const Color(0xFF6C63FF)),
              _buildFormatBadge('M4A', m4aCount, const Color(0xFF00C9A7)),
              if (flacCount > 0) _buildFormatBadge('FLAC', flacCount, const Color(0xFFFF6584)),
              if (otherCount > 0) _buildFormatBadge('Other', otherCount, const Color(0xFFFFB74D)),
            ],
          ),

          const SizedBox(height: 20),

          // Action Buttons: Shuffle All & Play All
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: allOffline.isEmpty
                      ? null
                      : () {
                          final shuffled = List<Song>.from(allOffline)..shuffle();
                          playerProvider.playPlaylist(shuffled, startIndex: 0);
                        },
                  icon: const Icon(Icons.shuffle_rounded, size: 18),
                  label: const Text('Shuffle Offline'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 4,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: allOffline.isEmpty
                      ? null
                      : () {
                          playerProvider.playPlaylist(allOffline, startIndex: 0);
                        },
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: const Text('Play All'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: Colors.white.withValues(alpha: 0.3), width: 1.2),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFormatBadge(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        '$label: $count',
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildAlbumsGrid(BuildContext context, PlayerProvider playerProvider, List<UserAlbum> albums) {
    final primary = Theme.of(context).colorScheme.primary;

    if (albums.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            children: [
              Icon(Icons.album_rounded, size: 54, color: AppColors.textTertiary.withValues(alpha: 0.5)),
              const SizedBox(height: 12),
              Text(
                'No offline album folders created',
                style: GoogleFonts.outfit(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                'Create custom albums to organize your offline audio files.',
                style: GoogleFonts.inter(color: AppColors.textTertiary, fontSize: 12.5),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () => _showCreateAlbumDialog(context, playerProvider),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Create New Album'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return SliverMainAxisGroup(
      slivers: [
        // Header with "+ Create Album" button
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${albums.length} Custom Albums',
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _showCreateAlbumDialog(context, playerProvider),
                  icon: Icon(Icons.add_circle_outline_rounded, color: primary, size: 18),
                  label: Text('New Album', style: TextStyle(color: primary, fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ),

        // Grid
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.1,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final album = albums[index];

                return GestureDetector(
                  onTap: () {
                    AlbumDetailsSheet.show(context, album.id);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceVariant.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: AppColors.glassBorder, width: 1),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: primary.withValues(alpha: 0.15),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(Icons.folder_special_rounded, color: primary, size: 22),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${album.songs.length} Tracks',
                                style: const TextStyle(color: AppColors.textSecondary, fontSize: 10, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              album.name,
                              style: GoogleFonts.outfit(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${album.isFolderBased ? 'Physical Folder' : 'Custom Album'} • ${album.formattedTotalSize}',
                              style: GoogleFonts.inter(color: AppColors.textTertiary, fontSize: 11),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
              childCount: albums.length,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context, PlayerProvider playerProvider) {
    final primary = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: primary.withValues(alpha: 0.12),
              border: Border.all(color: primary.withValues(alpha: 0.3), width: 1.5),
            ),
            child: Icon(Icons.offline_pin_rounded, size: 48, color: primary),
          ),
          const SizedBox(height: 20),
          Text(
            'No Offline Songs Found',
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Scan your device storage for local MP3/M4A audio files or download songs to listen offline.',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              color: AppColors.textTertiary,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () {
              playerProvider.scanLocalSongs();
              AppToast.show(context, 'Scanning storage for audio files...', type: ToastType.info);
            },
            icon: const Icon(Icons.search_rounded, size: 18),
            label: const Text('Scan Storage Now'),
            style: ElevatedButton.styleFrom(
              backgroundColor: primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ],
      ),
    );
  }
}


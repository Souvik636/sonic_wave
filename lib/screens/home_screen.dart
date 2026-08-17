import 'dart:io';
import 'dart:ui';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/song.dart';
import '../models/album.dart';
import '../providers/home_provider.dart';
import '../providers/player_provider.dart';
import '../theme/app_colors.dart';
import '../widgets/mini_player.dart';
import '../widgets/shimmer_loading.dart';
import '../widgets/song_tile.dart';
import '../widgets/song_album_art.dart';
import '../services/ai_categorization_service.dart';
import '../services/youtube_service.dart';
import '../services/archive_org_service.dart';
import 'search_screen.dart';
import 'discover_screen.dart';
import 'package:image_picker/image_picker.dart';
import 'radio_screen.dart';
import 'settings_screen.dart';
import '../providers/settings_provider.dart';
import '../widgets/app_toast.dart';
import '../services/storage_location_service.dart';
import '../services/download_service.dart';
import '../widgets/download_widgets.dart';
import '../widgets/offline_hub.dart';
import '../services/updater/github_release_client.dart';
import '../widgets/updater/update_dialog.dart';
import '../constants/app_version.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  int _currentNavIndex = 0;
  String _albumSearchQuery = '';
  String _albumSortType = 'name'; // 'name', 'size', 'date', 'songs'
  String _localSearchQuery = '';
  String _localFilterCategory = 'all'; // 'all', 'local', 'downloaded', 'edited'
  String _localSortType = 'title'; // 'title', 'artist', 'size', 'duration'
  late final TextEditingController _localSearchController;
  late final TextEditingController _albumSearchController;
  late AnimationController _fadeController;

  String _formatDate(DateTime dt) {
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${dt.day} ${months[dt.month - 1]}';
  }

  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _localSearchController = TextEditingController();
    _albumSearchController = TextEditingController();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _fadeController.forward();

    // Initialize home data
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<HomeProvider>().initialize();
      _autoCheckForUpdate();
    });
  }

  /// Silent background update check, throttled to once per 24 hours.
  /// Does not block the UI or show errors — only surfaces a dialog when
  /// a newer release is genuinely available.
  Future<void> _autoCheckForUpdate() async {
    try {
      if (!Platform.isAndroid) return;
      final shouldCheck = await GitHubReleaseClient.shouldAutoCheck();
      if (!shouldCheck) return;

      final appVersion = AppVersion.current;
      final client = GitHubReleaseClient(currentVersion: appVersion);
      final release = await client.checkForUpdate();

      if (release != null && release.targetAsset != null && mounted) {
        // Small delay so the home screen is fully rendered before showing.
        await Future<void>.delayed(const Duration(seconds: 2));
        if (mounted) {
          UpdateDialog.show(context, updateClient: client, release: release);
        }
      }
    } catch (e) {
      debugPrint('[AutoUpdate] Background check failed (silent): $e');
    }
  }

  @override
  void dispose() {
    _localSearchController.dispose();
    _albumSearchController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _currentNavIndex == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_currentNavIndex != 0) {
          setState(() {
            _currentNavIndex = 0;
          });
        }
      },
      child: Scaffold(
        body: FadeTransition(
          opacity: _fadeAnimation,
          child: Stack(
            children: [
              // Background gradient
              Container(
                decoration: const BoxDecoration(
                  gradient: AppColors.backgroundGradient,
                ),
              ),

              // Main content
              IndexedStack(
                index: _currentNavIndex,
                children: [
                  _buildHomePage(),
                  const SearchScreen(),
                  const DiscoverScreen(),
                  const RadioScreen(),
                  _buildStoragePage(),
                ],
              ),

              // Offline Connection Alert Banner
              Consumer<HomeProvider>(
                builder: (context, homeProvider, _) {
                  if (!homeProvider.isOffline) {
                    return const SizedBox.shrink();
                  }
                  return Positioned(
                    top: MediaQuery.of(context).padding.top + 70,
                    left: 20,
                    right: 20,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.redAccent.withValues(alpha: 0.3),
                          width: 0.8,
                        ),
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.wifi_off_rounded,
                            color: Colors.redAccent,
                            size: 20,
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Connection lost. Accessing offline downloads only.',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),

              // Playback Error SnackBar Trigger
              Consumer<PlayerProvider>(
                builder: (context, playerProvider, _) {
                  if (playerProvider.playbackError != null) {
                    final error = playerProvider.playbackError!;
                    final failedSong = playerProvider.currentSong;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      AppToast.show(
                        context,
                        error,
                        type: ToastType.error,
                        actionLabel: failedSong != null ? 'RETRY' : null,
                        onAction: failedSong != null
                            ? () => playerProvider.playSong(failedSong)
                            : null,
                      );
                      playerProvider.clearPlaybackError();
                    });
                  }
                  return const SizedBox.shrink();
                },
              ),

              // Mini player
              Positioned(
                left: 0,
                right: 0,
                bottom: 62,
                child: Consumer<PlayerProvider>(
                  builder: (context, playerProvider, _) {
                    if (!playerProvider.hasCurrentSong) {
                      return const SizedBox.shrink();
                    }
                    return const MiniPlayer();
                  },
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: _buildBottomNav(),
      ),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.95),
        border: Border(
          top: BorderSide(
            color: AppColors.divider.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
      ),
      child: BottomNavigationBar(
        currentIndex: _currentNavIndex,
        onTap: (index) => setState(() => _currentNavIndex = index),
        backgroundColor: Colors.transparent,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedFontSize: 11,
        unselectedFontSize: 10,
        selectedItemColor: Theme.of(context).colorScheme.primary,
        unselectedItemColor: AppColors.textTertiary,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_rounded, size: 24),
            activeIcon: Icon(Icons.home_rounded, size: 26),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.search_rounded, size: 24),
            activeIcon: Icon(Icons.search_rounded, size: 26),
            label: 'Search',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.explore_rounded, size: 24),
            activeIcon: Icon(Icons.explore_rounded, size: 26),
            label: 'Discover',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.radio_rounded, size: 24),
            activeIcon: Icon(Icons.radio_rounded, size: 26),
            label: 'Radio',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.storage_rounded, size: 24),
            activeIcon: Icon(Icons.storage_rounded, size: 26),
            label: 'Storage',
          ),
        ],
      ),
    );
  }

  Widget _buildHomePage() {
    final settings = Provider.of<SettingsProvider>(context);
    return Consumer<HomeProvider>(
      builder: (context, homeProvider, _) {
        if (settings.offlineModeOnly) {
          return const OfflineHub();
        }

        return RefreshIndicator(
          onRefresh: () => homeProvider.refresh(),
          color: Theme.of(context).colorScheme.primary,
          backgroundColor: AppColors.surface,
          displacement: 70,
          edgeOffset: MediaQuery.of(context).padding.top + 60,
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              // App bar
              SliverAppBar(
                floating: true,
                backgroundColor: Colors.transparent,
                toolbarHeight: 70,
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildGreetingWidget(context),
                    const SizedBox(height: 4),
                    ShaderMask(
                      shaderCallback: (bounds) => LinearGradient(
                        colors: [
                          Colors.white,
                          Theme.of(context).colorScheme.primary,
                        ],
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                      ).createShader(bounds),
                      child: Text(
                        'SonicWave',
                        style: Theme.of(context).textTheme.headlineLarge
                            ?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                      ),
                    ),
                  ],
                ),
                actions: [
                  // Live refresh indicator
                  if (homeProvider.isRefreshing)
                    Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation(
                                Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Updating',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  // Quick Offline mode toggle
                  Container(
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceVariant,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      onPressed: () {
                        settings.setOfflineModeOnly(true);
                      },
                      icon: const Icon(
                        Icons.cloud_queue_rounded,
                        color: AppColors.textSecondary,
                        size: 22,
                      ),
                      tooltip: 'Go Offline',
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.only(right: 16),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceVariant,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => const SettingsScreen(),
                          ),
                        );
                      },
                      icon: const Icon(
                        Icons.settings_rounded,
                        color: AppColors.textSecondary,
                        size: 22,
                      ),
                    ),
                  ),
                ],
              ),

              // Trending section
              SliverToBoxAdapter(
                child: _StaggeredListSlideIn(
                  index: 0,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 14),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 4,
                              height: 20,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Theme.of(context).colorScheme.primary,
                                    AppColors.secondary,
                                  ],
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                ),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'Trending Now',
                              style: Theme.of(context).textTheme.headlineMedium,
                            ),
                            const SizedBox(width: 8),
                            const _LivePulseDot(),
                          ],
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => SectionDetailScreen(
                                  title: 'Trending Now',
                                  songs: homeProvider.trendingSongs,
                                ),
                              ),
                            );
                          },
                          child: Text(
                            'See All',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Trending horizontal list
              SliverToBoxAdapter(
                child: homeProvider.isLoading
                    ? const ShimmerHorizontalList(
                        cardHeight: 250,
                        cardWidth: 190,
                      )
                    : _StaggeredListSlideIn(
                        index: 1,
                        child: _buildTrendingCards(homeProvider.trendingSongs),
                      ),
              ),

              // Recently Played
              SliverToBoxAdapter(child: _buildRecentlyPlayedSection()),

              ...homeProvider.categorySongs.entries
                  .toList()
                  .asMap()
                  .entries
                  .map((indexed) {
                    return SliverToBoxAdapter(
                      child: _StaggeredListSlideIn(
                        index: indexed.key + 2,
                        child: _buildCategorySection(
                          indexed.value.key,
                          indexed.value.value,
                        ),
                      ),
                    );
                  }),

              // Shimmer placeholders for categories still loading in
              if (homeProvider.categorySongs.length <
                      HomeProvider.categories.length &&
                  !homeProvider.isLoading)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(top: 20),
                    child: ShimmerLoadingList(itemCount: 3),
                  ),
                ),

              // Bottom padding for mini player
              const SliverToBoxAdapter(child: SizedBox(height: 140)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTrendingCards(List<Song> songs) {
    if (songs.isEmpty) {
      return const SizedBox(height: 250);
    }

    return SizedBox(
      height: 250,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: songs.length.clamp(0, 10),
        itemBuilder: (context, index) {
          final song = songs[index];
          return _TrendingCard(
            song: song,
            index: index,
            onTap: () {
              context.read<PlayerProvider>().playPlaylist(
                songs,
                startIndex: index,
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildRecentlyPlayedSection() {
    return Consumer<PlayerProvider>(
      builder: (context, playerProvider, _) {
        final recentlyPlayed = playerProvider.recentlyPlayed;
        if (recentlyPlayed.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 14),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.history_rounded,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Recently Played',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ],
              ),
            ),
            ...recentlyPlayed.take(5).map((song) => SongTile(song: song)),
          ],
        );
      },
    );
  }

  Widget _buildCategorySection(String category, List<Song> songs) {
    if (songs.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 4,
                    height: 20,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Theme.of(context).colorScheme.primary,
                          AppColors.secondary,
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    category,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ],
              ),
              TextButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          SectionDetailScreen(title: category, songs: songs),
                    ),
                  );
                },
                child: Text(
                  'See All',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
        ...songs
            .take(5)
            .toList()
            .asMap()
            .entries
            .map(
              (entry) => SongTile(
                song: entry.value,
                index: entry.key,
                onTap: () {
                  context.read<PlayerProvider>().playPlaylist(
                    songs,
                    startIndex: entry.key,
                  );
                },
              ),
            ),
      ],
    );
  }

  Widget _buildStoragePage() {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(110),
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                  child: Text(
                    'Storage',
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: TabBar(
                    indicatorSize: TabBarIndicatorSize.tab,
                    dividerColor: Colors.transparent,
                    indicator: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    labelColor: Colors.white,
                    unselectedLabelColor: AppColors.textTertiary,
                    labelStyle: GoogleFonts.outfit(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                    unselectedLabelStyle: GoogleFonts.outfit(
                      fontWeight: FontWeight.w500,
                      fontSize: 13,
                    ),
                    tabs: const [
                      Tab(text: 'Local'),
                      Tab(text: 'Albums'),
                      Tab(text: 'Downloads'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        body: TabBarView(
          physics: const BouncingScrollPhysics(),
          children: [_buildLocalTab(), _buildAlbumsTab(), _buildDownloadsTab()],
        ),
      ),
    );
  }

  Widget _buildAlbumsGrid(
    PlayerProvider provider,
    List<UserAlbum> filteredAlbums, {
    String? highlightQuery,
  }) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
          childAspectRatio: 0.85,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          // First item is a "Create Album" placeholder
          if (index == 0) {
            return _buildCreateAlbumCard(context, provider);
          }
          final album = filteredAlbums[index - 1];
          return _buildAlbumCard(
            context,
            album,
            provider,
            highlightQuery: highlightQuery,
          );
        }, childCount: filteredAlbums.length + 1),
      ),
    );
  }

  Widget _buildCreateAlbumCard(BuildContext context, PlayerProvider provider) {
    return GestureDetector(
      onTap: () => _showCreateAlbumDialog(context, provider),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: AppColors.glassBorder.withValues(alpha: 0.15),
            style: BorderStyle.solid,
            width: 1,
          ),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.add_circle_outline_rounded,
              size: 36,
              color: AppColors.textSecondary,
            ),
            SizedBox(height: 10),
            Text(
              'Create Album',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 2),
            Text(
              'Custom playlist',
              style: TextStyle(color: AppColors.textTertiary, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlbumCard(
    BuildContext context,
    UserAlbum album,
    PlayerProvider provider, {
    String? highlightQuery,
  }) {
    final hasThumbnail = album.thumbnail.isNotEmpty;
    Song? matchedSong;
    if (highlightQuery != null && highlightQuery.trim().isNotEmpty) {
      final q = highlightQuery.trim().toLowerCase();
      for (final s in album.songs) {
        if (s.title.toLowerCase().contains(q) ||
            s.artist.toLowerCase().contains(q)) {
          matchedSong = s;
          break;
        }
      }
    }

    final primaryColor = Theme.of(context).colorScheme.primary;

    return _AnimatedPressScale(
      onTap: () => _showAlbumDetailsSheet(
        context,
        album,
        provider,
        highlightQuery: highlightQuery,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: matchedSong != null
                ? primaryColor.withValues(alpha: 0.7)
                : AppColors.glassBorder.withValues(alpha: 0.2),
            width: matchedSong != null ? 1.2 : 0.8,
          ),
          boxShadow: matchedSong != null
              ? [
                  BoxShadow(
                    color: primaryColor.withValues(alpha: 0.2),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thumbnail
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (hasThumbnail)
                    album.thumbnail.startsWith('http')
                        ? CachedNetworkImage(
                            imageUrl: album.thumbnail,
                            fit: BoxFit.cover,
                            errorWidget: (context, url, error) =>
                                _buildAlbumFallbackArt(album),
                          )
                        : Image.file(
                            File(album.thumbnail),
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) =>
                                _buildAlbumFallbackArt(album),
                          )
                  else
                    _buildAlbumFallbackArt(album),

                  // Size overlay
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.1),
                          width: 0.5,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.storage_rounded,
                            size: 8,
                            color: AppColors.primaryLight,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            album.formattedTotalSize,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 8,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Last updated date overlay
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.1),
                          width: 0.5,
                        ),
                      ),
                      child: Text(
                        _formatDate(album.lastUpdated),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 8,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),

                  // Dark gradient overlay at bottom
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    height: 50,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.8),
                          ],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                      ),
                    ),
                  ),
                  // Matched song pill badge if searched
                  if (matchedSong != null)
                    Positioned(
                      bottom: 8,
                      left: 8,
                      right: 48,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: primaryColor.withValues(alpha: 0.90),
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.4),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.music_note_rounded,
                              size: 10,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 3),
                            Expanded(
                              child: Text(
                                matchedSong.title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  // Play button overlay
                  if (album.songs.isNotEmpty)
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        child: Center(
                          child: Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Title & Info
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          if (album.isFolderBased) ...[
                            Icon(
                              Icons.folder_rounded,
                              size: 10,
                              color: Colors.amber.withValues(alpha: 0.8),
                            ),
                            const SizedBox(width: 4),
                          ],
                          Text(
                            '${album.songCount} track${album.songCount == 1 ? '' : 's'}',
                            style: const TextStyle(
                              color: AppColors.textTertiary,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: album.isFolderBased
                              ? Colors.amber.withValues(alpha: 0.15)
                              : album.isCustom
                              ? AppColors.primary.withValues(alpha: 0.15)
                              : AppColors.secondary.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          album.isFolderBased
                              ? 'Folder'
                              : album.isCustom
                              ? 'Custom'
                              : 'Prefilled',
                          style: TextStyle(
                            color: album.isFolderBased
                                ? Colors.amber
                                : album.isCustom
                                ? AppColors.primaryLight
                                : AppColors.secondaryLight,
                            fontSize: 8,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlbumFallbackArt(UserAlbum album) {
    // Generate distinct gradient colors based on album name
    final nameHash = album.name.hashCode.abs();
    final gradientIndex = nameHash % 4;
    final gradients = [
      [const Color(0xFF6C63FF), const Color(0xFF00C9A7)],
      [const Color(0xFFFF6584), const Color(0xFFFF9A5C)],
      [const Color(0xFF845EC2), const Color(0xFFB39DDB)],
      [const Color(0xFF00B4D8), const Color(0xFF6C63FF)],
    ];
    final selectedColors = gradients[gradientIndex];
    final initials = album.name.length >= 2
        ? album.name.substring(0, 2).toUpperCase()
        : album.name.substring(0, 1).toUpperCase();

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: selectedColors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Text(
          initials,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          ),
        ),
      ),
    );
  }

  void _showCreateAlbumDialog(BuildContext context, PlayerProvider provider) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        contentPadding: EdgeInsets.zero,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Premium header with gradient
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppColors.primary.withValues(alpha: 0.2),
                    AppColors.secondary.withValues(alpha: 0.08),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.primary.withValues(alpha: 0.15),
                      border: Border.all(
                        color: AppColors.primary.withValues(alpha: 0.3),
                        width: 1.5,
                      ),
                    ),
                    child: const Icon(
                      Icons.library_add_rounded,
                      color: AppColors.primaryLight,
                      size: 28,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Create Album',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Organize your songs into a custom collection',
                    style: TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            // Input area
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: TextField(
                controller: controller,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'Album name...',
                  hintStyle: TextStyle(
                    color: AppColors.textTertiary.withValues(alpha: 0.5),
                  ),
                  prefixIcon: const Icon(
                    Icons.album_rounded,
                    color: AppColors.textTertiary,
                    size: 20,
                  ),
                  filled: true,
                  fillColor: AppColors.surfaceVariant.withValues(alpha: 0.5),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                      color: AppColors.glassBorder.withValues(alpha: 0.2),
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                      color: AppColors.glassBorder.withValues(alpha: 0.1),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(
                      color: AppColors.primary,
                      width: 1.5,
                    ),
                  ),
                ),
                autofocus: true,
              ),
            ),
            // Action buttons
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: AppColors.primaryGradient,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.3),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            final name = controller.text.trim();
                            if (name.isNotEmpty) {
                              provider.createAlbum(name);
                              Navigator.pop(ctx);
                            }
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 14),
                            child: Center(
                              child: Text(
                                'Create Album',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAlbumDetailsSheet(
    BuildContext context,
    UserAlbum album,
    PlayerProvider provider, {
    String? highlightQuery,
  }) {
    final scrollController = ScrollController();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        String searchQuery = '';
        String songSortType =
            'default'; // 'default', 'title', 'size', 'duration'
        final primaryColor = Theme.of(context).colorScheme.primary;

        return StatefulBuilder(
          builder: (context, setSheetState) {
            // Fetch updated album instance from provider to keep it in sync after edits
            final currentAlbum = provider.albums.firstWhere(
              (a) => a.id == album.id,
              orElse: () => album,
            );
            final hasThumbnail = currentAlbum.thumbnail.isNotEmpty;

            final filteredSongs = currentAlbum.songs.where((s) {
              final query = searchQuery.toLowerCase();
              return s.title.toLowerCase().contains(query) ||
                  s.artist.toLowerCase().contains(query);
            }).toList();

            if (songSortType == 'title') {
              filteredSongs.sort(
                (a, b) =>
                    a.title.toLowerCase().compareTo(b.title.toLowerCase()),
              );
            } else if (songSortType == 'size') {
              filteredSongs.sort(
                (a, b) => b.fileSizeInBytes.compareTo(a.fileSizeInBytes),
              );
            } else if (songSortType == 'duration') {
              filteredSongs.sort((a, b) => b.duration.compareTo(a.duration));
            }

            // Target song to auto-scroll & highlight
            String? targetSongId;
            if (highlightQuery != null && highlightQuery.trim().isNotEmpty) {
              final q = highlightQuery.trim().toLowerCase();
              for (final s in filteredSongs) {
                if (s.title.toLowerCase().contains(q) ||
                    s.artist.toLowerCase().contains(q)) {
                  targetSongId = s.videoId;
                  break;
                }
              }
            }
            // Fallback: Currently playing song if inside this album
            if (targetSongId == null && provider.currentSong != null) {
              if (filteredSongs.any(
                (s) => s.videoId == provider.currentSong!.videoId,
              )) {
                targetSongId = provider.currentSong!.videoId;
              }
            }

            // Trigger smooth auto-scroll to matched/playing song position
            if (targetSongId != null) {
              final targetIdx = filteredSongs.indexWhere(
                (s) => s.videoId == targetSongId,
              );
              if (targetIdx >= 0) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (scrollController.hasClients) {
                    final targetOffset = (targetIdx * 76.0).clamp(
                      0.0,
                      scrollController.position.maxScrollExtent,
                    );
                    scrollController.animateTo(
                      targetOffset,
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeOutCubic,
                    );
                  }
                });
              }
            }

            return Container(
              height: MediaQuery.of(context).size.height * 0.80,
              decoration: const BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                children: [
                  // Drag handle
                  Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 10),
                    width: 40,
                    height: 5,
                    decoration: BoxDecoration(
                      color: AppColors.textTertiary.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  // Album info header with background gradient & fade+slide transition
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0.0, end: 1.0),
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOutCubic,
                    builder: (context, animValue, child) {
                      return Transform.translate(
                        offset: Offset(0, 20 * (1.0 - animValue)),
                        child: Opacity(opacity: animValue, child: child),
                      );
                    },
                    child: Container(
                      width: double.infinity,
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            AppColors.surfaceVariant.withValues(alpha: 0.4),
                            AppColors.surfaceVariant.withValues(alpha: 0.0),
                          ],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: AppColors.glassBorder.withValues(alpha: 0.05),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          // Interactive Thumbnail Art
                          GestureDetector(
                            onTap: () async {
                              showModalBottomSheet(
                                context: context,
                                backgroundColor: AppColors.surface,
                                shape: const RoundedRectangleBorder(
                                  borderRadius: BorderRadius.vertical(
                                    top: Radius.circular(20),
                                  ),
                                ),
                                builder: (ctx) => SafeArea(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ListTile(
                                        leading: const Icon(
                                          Icons.photo_library_rounded,
                                          color: Colors.white,
                                        ),
                                        title: const Text(
                                          'Choose Cover from Gallery',
                                          style: TextStyle(color: Colors.white),
                                        ),
                                        onTap: () async {
                                          Navigator.pop(ctx);
                                          final picker = ImagePicker();
                                          final image = await picker.pickImage(
                                            source: ImageSource.gallery,
                                          );
                                          if (image != null) {
                                            await provider.updateAlbumCover(
                                              currentAlbum.id,
                                              image.path,
                                            );
                                            setSheetState(() {});
                                          }
                                        },
                                      ),
                                      if (currentAlbum.coverImagePath != null)
                                        ListTile(
                                          leading: const Icon(
                                            Icons.no_photography_rounded,
                                            color: Colors.redAccent,
                                          ),
                                          title: const Text(
                                            'Remove Custom Cover',
                                            style: TextStyle(
                                              color: Colors.redAccent,
                                            ),
                                          ),
                                          onTap: () async {
                                            Navigator.pop(ctx);
                                            await provider.updateAlbumCover(
                                              currentAlbum.id,
                                              null,
                                            );
                                            setSheetState(() {});
                                          },
                                        ),
                                    ],
                                  ),
                                ),
                              );
                            },
                            child: Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(14),
                                  child: SizedBox(
                                    width: 72,
                                    height: 72,
                                    child: hasThumbnail
                                        ? (currentAlbum.thumbnail.startsWith(
                                                'http',
                                              )
                                              ? CachedNetworkImage(
                                                  imageUrl:
                                                      currentAlbum.thumbnail,
                                                  fit: BoxFit.cover,
                                                  errorWidget:
                                                      (context, url, error) =>
                                                          _buildAlbumFallbackArt(
                                                            currentAlbum,
                                                          ),
                                                )
                                              : Image.file(
                                                  File(currentAlbum.thumbnail),
                                                  key: ValueKey(
                                                    'album_cover_${currentAlbum.id}_${currentAlbum.lastUpdated.millisecondsSinceEpoch}',
                                                  ),
                                                  fit: BoxFit.cover,
                                                  errorBuilder:
                                                      (
                                                        context,
                                                        error,
                                                        stackTrace,
                                                      ) =>
                                                          _buildAlbumFallbackArt(
                                                            currentAlbum,
                                                          ),
                                                ))
                                        : _buildAlbumFallbackArt(currentAlbum),
                                  ),
                                ),
                                Positioned.fill(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: 0.3,
                                      ),
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: const Center(
                                      child: Icon(
                                        Icons.camera_alt_rounded,
                                        color: Colors.white70,
                                        size: 20,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          // Titles & Metadata
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  currentAlbum.name,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    if (currentAlbum.isFolderBased) ...[
                                      Icon(
                                        Icons.folder_rounded,
                                        size: 12,
                                        color: Colors.amber.withValues(
                                          alpha: 0.8,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                    ],
                                    Expanded(
                                      child: Text(
                                        '${currentAlbum.isFolderBased
                                            ? 'Folder Album'
                                            : currentAlbum.isCustom
                                            ? 'Custom Album'
                                            : 'Category Album'} • ${currentAlbum.songCount} songs',
                                        style: const TextStyle(
                                          color: AppColors.textTertiary,
                                          fontSize: 12,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Size: ${currentAlbum.formattedTotalSize} • Updated: ${_formatDate(currentAlbum.lastUpdated)}',
                                  style: const TextStyle(
                                    color: AppColors.textTertiary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Play button
                          if (currentAlbum.songs.isNotEmpty)
                            IconButton(
                              style: IconButton.styleFrom(
                                backgroundColor: primaryColor,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.all(12),
                              ),
                              icon: const Icon(
                                Icons.play_arrow_rounded,
                                size: 26,
                              ),
                              onPressed: () {
                                provider.playPlaylist(
                                  currentAlbum.songs,
                                  startIndex: 0,
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Edit & Delete actions
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton.icon(
                          onPressed: () => _showManageAlbumSongsDialog(
                            context,
                            currentAlbum,
                            provider,
                            () {
                              setSheetState(() {});
                            },
                          ),
                          icon: const Icon(Icons.edit_rounded, size: 16),
                          label: const Text('Manage Songs'),
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.primaryLight,
                          ),
                        ),
                        if (currentAlbum.isCustom) ...[
                          const SizedBox(width: 10),
                          TextButton.icon(
                            onPressed: () {
                              _confirmDeleteAlbumWithProtection(
                                context,
                                currentAlbum,
                                provider,
                              );
                            },
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 16,
                            ),
                            label: const Text('Delete'),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.redAccent,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const Divider(height: 20, color: AppColors.divider),

                  // Song Search & Sorting bar
                  if (currentAlbum.songs.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 6,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Search songs in this album...',
                                hintStyle: const TextStyle(
                                  color: AppColors.textTertiary,
                                  fontSize: 12,
                                ),
                                prefixIcon: const Icon(
                                  Icons.search_rounded,
                                  color: AppColors.textTertiary,
                                  size: 18,
                                ),
                                filled: true,
                                fillColor: AppColors.surfaceVariant.withValues(
                                  alpha: 0.5,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 10,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                              onChanged: (val) {
                                setSheetState(() {
                                  searchQuery = val;
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Container(
                            decoration: BoxDecoration(
                              color: AppColors.surfaceVariant.withValues(
                                alpha: 0.5,
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: PopupMenuButton<String>(
                              icon: const Icon(
                                Icons.filter_list_rounded,
                                color: Colors.white,
                              ),
                              tooltip: 'Sort Songs',
                              onSelected: (val) {
                                setSheetState(() {
                                  songSortType = val;
                                });
                              },
                              color: AppColors.surface,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              itemBuilder: (ctx) => [
                                const PopupMenuItem(
                                  value: 'default',
                                  child: Text(
                                    'Default Order',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'title',
                                  child: Text(
                                    'Sort by Title',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'size',
                                  child: Text(
                                    'Sort by Size',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'duration',
                                  child: Text(
                                    'Sort by Duration',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                  // Album songs list with auto scroll, equalizer animation, and info details option
                  Expanded(
                    child: currentAlbum.songs.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.music_note_rounded,
                                  size: 48,
                                  color: AppColors.textTertiary,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'This album is empty',
                                  style: TextStyle(
                                    color: AppColors.textTertiary.withValues(
                                      alpha: 0.7,
                                    ),
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : (filteredSongs.isEmpty
                              ? const Center(
                                  child: Text(
                                    'No matching songs found',
                                    style: TextStyle(
                                      color: AppColors.textTertiary,
                                      fontSize: 13,
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  controller: scrollController,
                                  physics: const BouncingScrollPhysics(),
                                  padding: const EdgeInsets.only(bottom: 24),
                                  itemCount: filteredSongs.length,
                                  itemBuilder: (context, index) {
                                    final song = filteredSongs[index];
                                    final isCurrentlyPlaying =
                                        provider.isPlaying &&
                                        (provider.currentSong?.videoId ==
                                            song.videoId);
                                    final isMatched =
                                        targetSongId == song.videoId;

                                    return _StaggeredListSlideIn(
                                      index: index,
                                      child: AnimatedContainer(
                                        duration: const Duration(
                                          milliseconds: 300,
                                        ),
                                        margin: const EdgeInsets.symmetric(
                                          horizontal: 20,
                                          vertical: 6,
                                        ),
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: isCurrentlyPlaying
                                              ? primaryColor.withValues(
                                                  alpha: 0.18,
                                                )
                                              : (isMatched
                                                    ? primaryColor.withValues(
                                                        alpha: 0.10,
                                                      )
                                                    : AppColors.surfaceVariant
                                                          .withValues(
                                                            alpha: 0.25,
                                                          )),
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                          border: Border.all(
                                            color: isCurrentlyPlaying
                                                ? primaryColor.withValues(
                                                    alpha: 0.7,
                                                  )
                                                : (isMatched
                                                      ? primaryColor.withValues(
                                                          alpha: 0.4,
                                                        )
                                                      : Colors.white.withValues(
                                                          alpha: 0.05,
                                                        )),
                                            width:
                                                (isCurrentlyPlaying ||
                                                    isMatched)
                                                ? 1.2
                                                : 0.5,
                                          ),
                                          boxShadow: isCurrentlyPlaying
                                              ? [
                                                  BoxShadow(
                                                    color: primaryColor
                                                        .withValues(
                                                          alpha: 0.25,
                                                        ),
                                                    blurRadius: 10,
                                                    offset: const Offset(0, 2),
                                                  ),
                                                ]
                                              : null,
                                        ),
                                        child: ListTile(
                                          contentPadding: EdgeInsets.zero,
                                          leading: Stack(
                                            children: [
                                              ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                child: SongAlbumArt(
                                                  song: song,
                                                  width: 44,
                                                  height: 44,
                                                ),
                                              ),
                                              if (isCurrentlyPlaying)
                                                Positioned.fill(
                                                  child: Container(
                                                    decoration: BoxDecoration(
                                                      color: Colors.black
                                                          .withValues(
                                                            alpha: 0.55,
                                                          ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            8,
                                                          ),
                                                    ),
                                                    child: Center(
                                                      child:
                                                          _AnimatedEqualizerBars(
                                                            isPlaying: true,
                                                            color: primaryColor,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                          title: Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  song.title,
                                                  style: TextStyle(
                                                    color: isCurrentlyPlaying
                                                        ? primaryColor
                                                        : Colors.white,
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              if (isMatched &&
                                                  !isCurrentlyPlaying) ...[
                                                const SizedBox(width: 4),
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 5,
                                                        vertical: 1.5,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: primaryColor
                                                        .withValues(alpha: 0.2),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          4,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    'Matched',
                                                    style: TextStyle(
                                                      color: primaryColor,
                                                      fontSize: 8,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                          subtitle: Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  song.artist,
                                                  style: const TextStyle(
                                                    color:
                                                        AppColors.textTertiary,
                                                    fontSize: 11,
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              if (song
                                                  .formattedFileSize
                                                  .isNotEmpty) ...[
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 6,
                                                        vertical: 2,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: AppColors.primary
                                                        .withValues(
                                                          alpha: 0.15,
                                                        ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          6,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    song.formattedFileSize,
                                                    style: const TextStyle(
                                                      color: AppColors
                                                          .primaryLight,
                                                      fontSize: 8,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                              ],
                                              Text(
                                                song.formattedDuration,
                                                style: const TextStyle(
                                                  color: AppColors.textTertiary,
                                                  fontSize: 10,
                                                ),
                                              ),
                                            ],
                                          ),
                                          trailing: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              // Details Icon Button
                                              IconButton(
                                                icon: const Icon(
                                                  Icons.info_outline_rounded,
                                                  color: Colors.white70,
                                                  size: 18,
                                                ),
                                                tooltip: 'Song Details',
                                                onPressed: () =>
                                                    _showSongDetailsSheet(
                                                      context,
                                                      song,
                                                      provider,
                                                    ),
                                              ),
                                              // Move Song
                                              IconButton(
                                                icon: const Icon(
                                                  Icons.drive_file_move_rounded,
                                                  color: Colors.white70,
                                                  size: 18,
                                                ),
                                                tooltip: 'Move Song',
                                                onPressed: () async {
                                                  final targetAlbum =
                                                      await _showAlbumPickerForMove(
                                                        context,
                                                        provider,
                                                        currentAlbum.id,
                                                      );
                                                  if (targetAlbum == null ||
                                                      !context.mounted) {
                                                    return;
                                                  }
                                                  final op =
                                                      await _promptMoveType(
                                                        context,
                                                      );
                                                  if (op == null) return;
                                                  final success = await provider
                                                      .moveSongToAnotherAlbumFolder(
                                                        song,
                                                        targetAlbum.id,
                                                        physicalMove:
                                                            op.physicalMove,
                                                        isCopyMode:
                                                            op.isCopyMode,
                                                      );
                                                  if (context.mounted) {
                                                    final msg = op.isCopyMode
                                                        ? 'Copied to "${targetAlbum.name}"'
                                                        : (op.physicalMove
                                                              ? 'Moved to "${targetAlbum.name}"'
                                                              : 'Added to "${targetAlbum.name}"');
                                                    ScaffoldMessenger.of(
                                                      context,
                                                    ).showSnackBar(
                                                      SnackBar(
                                                        content: Text(
                                                          success
                                                              ? msg
                                                              : 'Failed to process song',
                                                        ),
                                                        backgroundColor: success
                                                            ? AppColors.success
                                                                  .withValues(
                                                                    alpha: 0.9,
                                                                  )
                                                            : AppColors.error
                                                                  .withValues(
                                                                    alpha: 0.9,
                                                                  ),
                                                      ),
                                                    );
                                                    setSheetState(() {});
                                                  }
                                                },
                                              ),
                                              // Remove Song
                                              IconButton(
                                                icon: const Icon(
                                                  Icons.delete_outline_rounded,
                                                  color: Colors.redAccent,
                                                  size: 18,
                                                ),
                                                tooltip: 'Remove Song',
                                                onPressed: () {
                                                  _showDeleteSongDialog(
                                                    context,
                                                    song,
                                                    currentAlbum,
                                                    provider,
                                                    () {
                                                      setSheetState(() {});
                                                    },
                                                  );
                                                },
                                              ),
                                            ],
                                          ),
                                          onTap: () {
                                            provider.playPlaylist(
                                              filteredSongs,
                                              startIndex: index,
                                            );
                                          },
                                        ),
                                      ),
                                    );
                                  },
                                )),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _confirmDeleteAlbumWithProtection(
    BuildContext context,
    UserAlbum album,
    PlayerProvider provider,
  ) {
    final otherAlbums = provider.albums.where((a) => a.id != album.id).toList();

    if (album.songs.isEmpty) {
      provider.deleteAlbum(album.id);
      Navigator.pop(context);
      return;
    }

    String? selectedTargetAlbumId = otherAlbums.isNotEmpty
        ? otherAlbums.first.id
        : null;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: const Color(0xFF16162C),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              const Icon(Icons.shield_outlined, color: Colors.amber, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Delete "${album.name}"?',
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This album contains ${album.songs.length} song(s). Please choose how to handle these tracks:',
                style: GoogleFonts.inter(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 16),
              if (otherAlbums.isNotEmpty) ...[
                Text(
                  'Move Songs to Another Album (Recommended):',
                  style: GoogleFonts.inter(
                    color: AppColors.primaryLight,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.white10,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: selectedTargetAlbumId,
                      dropdownColor: const Color(0xFF1E1E38),
                      isExpanded: true,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      items: otherAlbums.map((a) {
                        return DropdownMenuItem<String>(
                          value: a.id,
                          child: Text(a.name),
                        );
                      }).toList(),
                      onChanged: (val) {
                        setDlgState(() {
                          selectedTargetAlbumId = val;
                        });
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.amber.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      color: Colors.amber,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Choosing "Move to Recovery" preserves tracks in a hidden recovery folder with a RECOVERY badge tag.',
                        style: GoogleFonts.inter(
                          color: Colors.amber.shade200,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white60),
              ),
            ),
            if (otherAlbums.isNotEmpty)
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: () async {
                  Navigator.pop(ctx);
                  await provider.deleteAlbumWithProtection(
                    album.id,
                    targetAlbumId: selectedTargetAlbumId,
                  );
                  if (context.mounted) Navigator.pop(context);
                },
                icon: const Icon(
                  Icons.drive_file_move_rounded,
                  size: 16,
                  color: Colors.white,
                ),
                label: const Text(
                  'Move to Album',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber.shade900,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () async {
                Navigator.pop(ctx);
                await provider.deleteAlbumWithProtection(
                  album.id,
                  moveToRecovery: true,
                );
                if (context.mounted) Navigator.pop(context);
              },
              icon: const Icon(
                Icons.restore_from_trash_rounded,
                size: 16,
                color: Colors.white,
              ),
              label: const Text(
                'Move to Recovery',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSongDetailsSheet(
    BuildContext context,
    Song song,
    PlayerProvider provider,
  ) {
    final primaryColor = Theme.of(context).colorScheme.primary;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.95),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              border: Border.all(color: AppColors.glassBorder, width: 0.8),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),

                // Artwork & Title Header
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: SongAlbumArt(song: song, width: 64, height: 64),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            song.artist,
                            style: TextStyle(
                              color: primaryColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Divider(color: AppColors.divider),
                const SizedBox(height: 12),

                // Detailed Metadata Grid Cards
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 2.4,
                  children: [
                    _buildSongMetaCard(
                      'Duration',
                      song.formattedDuration,
                      Icons.timer_rounded,
                      primaryColor,
                    ),
                    _buildSongMetaCard(
                      'File Size',
                      song.formattedFileSize.isNotEmpty
                          ? song.formattedFileSize
                          : 'Streamed',
                      Icons.sd_card_rounded,
                      primaryColor,
                    ),
                    _buildSongMetaCard(
                      'Album / Folder',
                      song.albumFolderName ?? 'General Catalog',
                      Icons.album_rounded,
                      primaryColor,
                    ),
                    _buildSongMetaCard(
                      'Speed / Pitch',
                      '${song.speed}x / ${song.pitch}',
                      Icons.tune_rounded,
                      primaryColor,
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Location / Video ID Bar
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppColors.glassBorder,
                      width: 0.5,
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.insert_drive_file_rounded,
                        size: 16,
                        color: AppColors.textTertiary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          song.videoId,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                            fontFamily: 'monospace',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                // Actions Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          provider.playSong(song);
                        },
                        icon: const Icon(Icons.play_arrow_rounded, size: 20),
                        label: const Text('Play Now'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primaryColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton.filledTonal(
                      onPressed: () {
                        provider.addSongToQueue(song);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Added to Queue'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                      icon: const Icon(Icons.queue_music_rounded, size: 20),
                      tooltip: 'Add to Queue',
                    ),
                    Consumer<PlayerProvider>(
                      builder: (context, p, _) {
                        final isFav = p.isFavorite(song.videoId);
                        return IconButton.filledTonal(
                          onPressed: () {
                            p.toggleFavorite(song);
                          },
                          icon: Icon(
                            isFav
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            color: isFav ? Colors.redAccent : Colors.white,
                            size: 20,
                          ),
                          tooltip: 'Favorite',
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSongMetaCard(
    String label,
    String value,
    IconData icon,
    Color primaryColor,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.glassBorder.withValues(alpha: 0.1),
          width: 0.6,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: primaryColor),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.textTertiary,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showManageAlbumSongsDialog(
    BuildContext context,
    UserAlbum album,
    PlayerProvider provider,
    VoidCallback onUpdated,
  ) {
    final List<Song> allSongs = [];
    final Set<String> ids = {};

    // 1. Favorites
    for (final s in provider.favorites) {
      if (!ids.contains(s.videoId)) {
        allSongs.add(s);
        ids.add(s.videoId);
      }
    }
    // 2. Downloads
    for (final s in provider.downloadedSongs) {
      if (!ids.contains(s.videoId)) {
        allSongs.add(s);
        ids.add(s.videoId);
      }
    }
    // 3. Local Scanned
    for (final s in provider.localSongsMerged) {
      if (!ids.contains(s.videoId)) {
        allSongs.add(s);
        ids.add(s.videoId);
      }
    }
    // 4. Recently Played
    for (final s in provider.recentlyPlayed) {
      if (!ids.contains(s.videoId)) {
        allSongs.add(s);
        ids.add(s.videoId);
      }
    }

    if (allSongs.isEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text(
            'No Songs Available',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'To add songs to this album, please play some songs, favorite them, download them, or scan your local device storage.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    // Keep track of check state
    final selectedSongs = List<Song>.from(album.songs);

    showDialog(
      context: context,
      builder: (ctx) {
        String dialogSearchQuery = '';
        return AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: const Text(
            'Manage Album Songs',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SizedBox(
            width: MediaQuery.of(context).size.width * 0.9,
            height: 420,
            child: StatefulBuilder(
              builder: (ctx, setDialogState) {
                final filteredAllSongs = allSongs.where((song) {
                  final query = dialogSearchQuery.toLowerCase();
                  return song.title.toLowerCase().contains(query) ||
                      song.artist.toLowerCase().contains(query);
                }).toList();

                return Column(
                  children: [
                    TextField(
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Search songs to add...',
                        hintStyle: const TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 12,
                        ),
                        prefixIcon: const Icon(
                          Icons.search_rounded,
                          color: AppColors.textTertiary,
                          size: 18,
                        ),
                        filled: true,
                        fillColor: AppColors.surfaceVariant.withValues(
                          alpha: 0.4,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onChanged: (val) {
                        setDialogState(() {
                          dialogSearchQuery = val;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: filteredAllSongs.isEmpty
                          ? const Center(
                              child: Text(
                                'No matching songs found',
                                style: TextStyle(
                                  color: AppColors.textTertiary,
                                  fontSize: 13,
                                ),
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              itemCount: filteredAllSongs.length,
                              itemBuilder: (ctx, index) {
                                final song = filteredAllSongs[index];
                                final isChecked = selectedSongs.any(
                                  (s) => s.videoId == song.videoId,
                                );
                                final tag = _getSongSourceTag(song, provider);
                                final hasThumb = song.thumbnailUrl.isNotEmpty;

                                return InkWell(
                                  onTap: () {
                                    setDialogState(() {
                                      if (!isChecked) {
                                        selectedSongs.add(song);
                                      } else {
                                        selectedSongs.removeWhere(
                                          (s) => s.videoId == song.videoId,
                                        );
                                      }
                                    });
                                  },
                                  borderRadius: BorderRadius.circular(12),
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(
                                      vertical: 4,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isChecked
                                          ? AppColors.primary.withValues(
                                              alpha: 0.08,
                                            )
                                          : Colors.transparent,
                                      border: Border.all(
                                        color: isChecked
                                            ? AppColors.primary.withValues(
                                                alpha: 0.3,
                                              )
                                            : Colors.transparent,
                                        width: 1,
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          isChecked
                                              ? Icons.check_circle_rounded
                                              : Icons
                                                    .radio_button_unchecked_rounded,
                                          color: isChecked
                                              ? AppColors.primary
                                              : AppColors.textTertiary,
                                          size: 20,
                                        ),
                                        const SizedBox(width: 12),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          child: SizedBox(
                                            width: 40,
                                            height: 40,
                                            child: hasThumb
                                                ? (song.thumbnailUrl.startsWith(
                                                        'http',
                                                      )
                                                      ? CachedNetworkImage(
                                                          imageUrl:
                                                              song.thumbnailUrl,
                                                          fit: BoxFit.cover,
                                                          errorWidget:
                                                              (
                                                                context,
                                                                url,
                                                                error,
                                                              ) => const Icon(
                                                                Icons
                                                                    .music_note,
                                                                color: Colors
                                                                    .white54,
                                                              ),
                                                        )
                                                      : Image.file(
                                                          File(
                                                            song.thumbnailUrl,
                                                          ),
                                                          fit: BoxFit.cover,
                                                          errorBuilder:
                                                              (
                                                                context,
                                                                error,
                                                                stackTrace,
                                                              ) => const Icon(
                                                                Icons
                                                                    .music_note,
                                                                color: Colors
                                                                    .white54,
                                                              ),
                                                        ))
                                                : Container(
                                                    color: Colors.white10,
                                                    child: const Icon(
                                                      Icons.music_note,
                                                      color: Colors.white54,
                                                    ),
                                                  ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                song.title,
                                                style: TextStyle(
                                                  color: isChecked
                                                      ? Colors.white
                                                      : AppColors.textPrimary,
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 3),
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      song.artist,
                                                      style: const TextStyle(
                                                        color: AppColors
                                                            .textTertiary,
                                                        fontSize: 11,
                                                      ),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                  if (tag != null) ...[
                                                    const SizedBox(width: 6),
                                                    Container(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 5,
                                                            vertical: 1.5,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: _getTagBgColor(
                                                          tag,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              3,
                                                            ),
                                                      ),
                                                      child: Text(
                                                        tag.toUpperCase(),
                                                        style: const TextStyle(
                                                          color: Colors.white,
                                                          fontSize: 7,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Cancel',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
            TextButton(
              onPressed: () {
                provider.updateAlbumSongs(album.id, selectedSongs);
                Navigator.pop(ctx);
                onUpdated();
              },
              child: const Text(
                'Save',
                style: TextStyle(color: AppColors.primary),
              ),
            ),
          ],
        );
      },
    );
  }

  String? _getSongSourceTag(Song song, PlayerProvider provider) {
    if (provider.downloadedSongs.any((s) => s.videoId == song.videoId)) {
      return 'Downloaded';
    }
    if (song.isLocalFile) {
      return 'Local';
    }
    if (provider.recentlyPlayed.any((s) => s.videoId == song.videoId)) {
      return 'Recent';
    }
    return null;
  }

  Color _getTagBgColor(String tag) {
    switch (tag.toLowerCase()) {
      case 'favorite':
        return Colors.pink.withValues(alpha: 0.6);
      case 'downloaded':
        return Colors.green.withValues(alpha: 0.6);
      case 'local':
        return Colors.blue.withValues(alpha: 0.6);
      case 'recent':
        return Colors.orange.withValues(alpha: 0.6);
      default:
        return Colors.grey.withValues(alpha: 0.6);
    }
  }

  Widget _buildLocalTab() {
    return Consumer<PlayerProvider>(
      builder: (context, playerProvider, _) {
        final localSongs = playerProvider.localSongsMerged;
        final primaryColor = Theme.of(context).colorScheme.primary;
        final hasExternal = localSongs.any(
          (s) =>
              s.isLocalFile &&
              s.filePath != null &&
              !StorageLocationService().isFileInAppFolderSync(s.filePath!),
        );

        // Filter and sort local songs
        final searchQuery = _localSearchQuery.trim().toLowerCase();
        final filteredLocalSongs = localSongs.where((song) {
          if (_localFilterCategory == 'local' &&
              !song.id.startsWith('local_')) {
            return false;
          }
          if (_localFilterCategory == 'downloaded' &&
              song.id.startsWith('local_')) {
            return false;
          }
          if (_localFilterCategory == 'edited' && !song.isEdited) {
            return false;
          }

          if (searchQuery.isEmpty) return true;
          final titleMatch = song.title.toLowerCase().contains(searchQuery);
          final artistMatch = song.artist.toLowerCase().contains(searchQuery);
          final pathMatch = (song.filePath ?? '').toLowerCase().contains(
            searchQuery,
          );
          return titleMatch || artistMatch || pathMatch;
        }).toList();

        if (_localSortType == 'title') {
          filteredLocalSongs.sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          );
        } else if (_localSortType == 'artist') {
          filteredLocalSongs.sort(
            (a, b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()),
          );
        } else if (_localSortType == 'size') {
          filteredLocalSongs.sort(
            (a, b) => b.fileSizeInBytes.compareTo(a.fileSizeInBytes),
          );
        } else if (_localSortType == 'duration') {
          filteredLocalSongs.sort((a, b) => b.duration.compareTo(a.duration));
        }

        int totalBytes = 0;
        for (final song in filteredLocalSongs) {
          totalBytes += song.fileSizeInBytes;
        }
        final formattedTotalSize = totalBytes > 0
            ? '${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
            : '';

        return CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 12)),

            if (playerProvider.scanPermissionDenied)
              SliverToBoxAdapter(
                child: Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFB74D).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: const Color(0xFFFFB74D).withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: Color(0xFFFFB74D),
                        size: 24,
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Storage Permission Required',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Permission was denied. Grant storage access in app settings to scan audio files on your device.',
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () => openAppSettings(),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFFFFB74D),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                        ),
                        child: const Text(
                          'Settings',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Premium Glass Header & Quick Actions Bar
            SliverToBoxAdapter(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.glassBorder, width: 0.8),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: primaryColor.withValues(alpha: 0.15),
                            border: Border.all(
                              color: primaryColor.withValues(alpha: 0.3),
                              width: 1,
                            ),
                          ),
                          child: Icon(
                            Icons.folder_special_rounded,
                            color: primaryColor,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Local Music & Downloads',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${filteredLocalSongs.length} track(s)${formattedTotalSize.isNotEmpty ? ' • $formattedTotalSize' : ''}',
                                style: const TextStyle(
                                  color: AppColors.textTertiary,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: primaryColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${filteredLocalSongs.length}',
                            style: TextStyle(
                              color: primaryColor,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const BouncingScrollPhysics(),
                      child: Row(
                        children: [
                          // Scan Button
                          ElevatedButton.icon(
                            onPressed: () => playerProvider.scanLocalSongs(),
                            icon: playerProvider.isScanningLocal
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.refresh_rounded, size: 16),
                            label: Text(
                              playerProvider.isScanningLocal
                                  ? 'Scanning...'
                                  : 'Scan Storage',
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.surfaceVariant,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                            ),
                          ),
                          if (localSongs.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            // AI Organize Button
                            Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                gradient: LinearGradient(
                                  colors: [primaryColor, Colors.purpleAccent],
                                ),
                              ),
                              child: ElevatedButton.icon(
                                onPressed: () => _startAiCategorizationFlow(
                                  context,
                                  localSongs,
                                  playerProvider,
                                ),
                                icon: const Icon(
                                  Icons.auto_awesome_rounded,
                                  size: 16,
                                  color: Colors.white,
                                ),
                                label: const Text(
                                  'AI Organize',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 8,
                                  ),
                                ),
                              ),
                            ),
                          ],
                          if (hasExternal) ...[
                            const SizedBox(width: 8),
                            // Move to App Folder Button
                            OutlinedButton.icon(
                              onPressed: () => _showMoveSongsToAppFolderDialog(
                                context,
                                localSongs,
                                playerProvider,
                              ),
                              icon: const Icon(
                                Icons.drive_file_move_rounded,
                                size: 16,
                                color: AppColors.primaryLight,
                              ),
                              label: const Text(
                                'Move to sonicWave',
                                style: TextStyle(
                                  color: AppColors.primaryLight,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(
                                  color: AppColors.primaryLight.withValues(
                                    alpha: 0.4,
                                  ),
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 8,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            if (localSongs.isNotEmpty)
              SliverToBoxAdapter(
                child: _buildLocalFilterBar(
                  context,
                  playerProvider,
                  filteredLocalSongs,
                ),
              ),

            if (filteredLocalSongs.isEmpty)
              SliverFillRemaining(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 30),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.surfaceVariant.withValues(
                              alpha: 0.4,
                            ),
                            border: Border.all(
                              color: AppColors.glassBorder,
                              width: 1,
                            ),
                          ),
                          child: Icon(
                            Icons.library_music_rounded,
                            size: 56,
                            color: primaryColor.withValues(alpha: 0.6),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          localSongs.isEmpty
                              ? 'No Local Music Found'
                              : 'No Matching Tracks',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          localSongs.isEmpty
                              ? 'Scanned local audio files and offline downloads will appear here.'
                              : 'Try adjusting your search query or filter chips.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: AppColors.textTertiary,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          onPressed: () {
                            if (localSongs.isEmpty) {
                              playerProvider.scanLocalSongs();
                            } else {
                              _localSearchController.clear();
                              setState(() {
                                _localSearchQuery = '';
                                _localFilterCategory = 'all';
                              });
                            }
                          },
                          icon: Icon(
                            localSongs.isEmpty
                                ? Icons.search_rounded
                                : Icons.filter_alt_off_rounded,
                            size: 18,
                          ),
                          label: Text(
                            localSongs.isEmpty
                                ? 'Scan Storage Now'
                                : 'Clear Filters',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: primaryColor,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final localSong = filteredLocalSongs[index];
                  return _StaggeredListSlideIn(
                    index: index < 15 ? index : 15,
                    child: SongTile(
                      song: localSong,
                      index: index,
                      sourceTag: localSong.id.startsWith('local_')
                          ? 'local'
                          : 'downloaded',
                      onTap: () {
                        playerProvider.playPlaylist(
                          filteredLocalSongs,
                          startIndex: index,
                        );
                      },
                    ),
                  );
                }, childCount: filteredLocalSongs.length),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 140)),
          ],
        );
      },
    );
  }

  Widget _buildLocalFilterBar(
    BuildContext context,
    PlayerProvider playerProvider,
    List<Song> filteredSongs,
  ) {
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _localSearchController,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  onChanged: (val) {
                    setState(() {
                      _localSearchQuery = val;
                    });
                  },
                  decoration: InputDecoration(
                    hintText: 'Search title, artist or path...',
                    hintStyle: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 12,
                    ),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      color: AppColors.textTertiary,
                      size: 18,
                    ),
                    suffixIcon: _localSearchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(
                              Icons.clear_rounded,
                              color: AppColors.textTertiary,
                              size: 18,
                            ),
                            onPressed: () {
                              _localSearchController.clear();
                              setState(() {
                                _localSearchQuery = '';
                              });
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: AppColors.surfaceVariant.withValues(alpha: 0.4),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              PopupMenuButton<String>(
                initialValue: _localSortType,
                onSelected: (val) {
                  setState(() {
                    _localSortType = val;
                  });
                },
                icon: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.sort_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                itemBuilder: (ctx) => const [
                  PopupMenuItem(
                    value: 'title',
                    child: Text('Sort by Title (A-Z)'),
                  ),
                  PopupMenuItem(
                    value: 'artist',
                    child: Text('Sort by Artist (A-Z)'),
                  ),
                  PopupMenuItem(
                    value: 'size',
                    child: Text('Sort by File Size'),
                  ),
                  PopupMenuItem(
                    value: 'duration',
                    child: Text('Sort by Duration'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: Row(
                    children: [
                      _buildLocalCategoryChip('All', 'all', primaryColor),
                      const SizedBox(width: 6),
                      _buildLocalCategoryChip('Scanned', 'local', primaryColor),
                      const SizedBox(width: 6),
                      _buildLocalCategoryChip(
                        'Downloads',
                        'downloaded',
                        primaryColor,
                      ),
                      const SizedBox(width: 6),
                      _buildLocalCategoryChip('Edited', 'edited', primaryColor),
                    ],
                  ),
                ),
              ),
              if (filteredSongs.isNotEmpty) ...[
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () =>
                      playerProvider.playPlaylist(filteredSongs, startIndex: 0),
                  icon: const Icon(
                    Icons.play_circle_fill_rounded,
                    color: Colors.white,
                    size: 28,
                  ),
                  tooltip: 'Play All',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () {
                    final list = List<Song>.from(filteredSongs)..shuffle();
                    playerProvider.playPlaylist(list, startIndex: 0);
                  },
                  icon: Icon(
                    Icons.shuffle_rounded,
                    color: primaryColor,
                    size: 24,
                  ),
                  tooltip: 'Shuffle All',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLocalCategoryChip(
    String label,
    String categoryKey,
    Color primaryColor,
  ) {
    final isSelected = _localFilterCategory == categoryKey;
    return FilterChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
          color: isSelected ? Colors.white : AppColors.textSecondary,
        ),
      ),
      selected: isSelected,
      onSelected: (_) {
        setState(() {
          _localFilterCategory = categoryKey;
        });
      },
      backgroundColor: AppColors.surfaceVariant.withValues(alpha: 0.3),
      selectedColor: primaryColor.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: BorderSide(
        color: isSelected ? primaryColor : AppColors.glassBorder,
        width: isSelected ? 1.2 : 0.5,
      ),
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    );
  }

  Widget _buildAlbumsTab() {
    return Consumer2<PlayerProvider, SettingsProvider>(
      builder: (context, playerProvider, settingsProvider, _) {
        final isInternal =
            settingsProvider.storageType == StorageType.appInternal;

        final albums = List<UserAlbum>.from(playerProvider.albums);
        final searchQuery = _albumSearchQuery.trim().toLowerCase();
        final filteredAlbums = albums.where((album) {
          if (searchQuery.isEmpty) return true;
          final matchesAlbumName = album.name.toLowerCase().contains(
            searchQuery,
          );
          final matchesSongName = album.songs.any(
            (s) =>
                s.title.toLowerCase().contains(searchQuery) ||
                s.artist.toLowerCase().contains(searchQuery),
          );
          return matchesAlbumName || matchesSongName;
        }).toList();

        if (_albumSortType == 'name') {
          filteredAlbums.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
        } else if (_albumSortType == 'size') {
          filteredAlbums.sort(
            (a, b) => b.totalSizeInBytes.compareTo(a.totalSizeInBytes),
          );
        } else if (_albumSortType == 'date') {
          filteredAlbums.sort((a, b) => b.lastUpdated.compareTo(a.lastUpdated));
        } else if (_albumSortType == 'songs') {
          filteredAlbums.sort((a, b) => b.songCount.compareTo(a.songCount));
        }

        return CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
            if (isInternal)
              SliverToBoxAdapter(
                child: _buildFolderOnboardingBanner(
                  context,
                  playerProvider,
                  settingsProvider,
                ),
              ),
            SliverToBoxAdapter(child: _buildAlbumFilterBar()),
            _buildAlbumsGrid(
              playerProvider,
              filteredAlbums,
              highlightQuery: _albumSearchQuery,
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 140)),
          ],
        );
      },
    );
  }

  Widget _buildAlbumFilterBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _albumSearchController,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              onChanged: (val) {
                setState(() {
                  _albumSearchQuery = val;
                });
              },
              decoration: InputDecoration(
                hintText: 'Search albums...',
                hintStyle: const TextStyle(
                  color: AppColors.textTertiary,
                  fontSize: 12,
                ),
                prefixIcon: const Icon(
                  Icons.search_rounded,
                  color: AppColors.textTertiary,
                  size: 18,
                ),
                suffixIcon: _albumSearchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(
                          Icons.clear_rounded,
                          color: AppColors.textTertiary,
                          size: 18,
                        ),
                        onPressed: () {
                          _albumSearchController.clear();
                          setState(() {
                            _albumSearchQuery = '';
                          });
                        },
                      )
                    : null,
                filled: true,
                fillColor: AppColors.surfaceVariant.withValues(alpha: 0.4),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: PopupMenuButton<String>(
              icon: const Icon(Icons.sort_rounded, color: Colors.white),
              tooltip: 'Sort Albums',
              onSelected: (val) {
                setState(() {
                  _albumSortType = val;
                });
              },
              color: AppColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                  value: 'name',
                  child: Row(
                    children: [
                      Icon(
                        Icons.sort_by_alpha_rounded,
                        color: Colors.white70,
                        size: 18,
                      ),
                      SizedBox(width: 10),
                      Text(
                        'Name (A-Z)',
                        style: TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'size',
                  child: Row(
                    children: [
                      Icon(
                        Icons.storage_rounded,
                        color: Colors.white70,
                        size: 18,
                      ),
                      SizedBox(width: 10),
                      Text(
                        'Size (Largest)',
                        style: TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'date',
                  child: Row(
                    children: [
                      Icon(
                        Icons.update_rounded,
                        color: Colors.white70,
                        size: 18,
                      ),
                      SizedBox(width: 10),
                      Text(
                        'Last Updated',
                        style: TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'songs',
                  child: Row(
                    children: [
                      Icon(
                        Icons.music_note_rounded,
                        color: Colors.white70,
                        size: 18,
                      ),
                      SizedBox(width: 10),
                      Text(
                        'Song Count',
                        style: TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFolderOnboardingBanner(
    BuildContext context,
    PlayerProvider playerProvider,
    SettingsProvider settingsProvider,
  ) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (context, animValue, child) {
        return Transform.translate(
          offset: Offset(0, 24 * (1.0 - animValue)),
          child: Opacity(opacity: animValue, child: child),
        );
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
              Colors.purpleAccent.withValues(alpha: 0.05),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.25),
            width: 0.8,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.folder_open_rounded,
                    color: AppColors.primaryLight,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Enable Folder Organization',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Keep your audio files visible in phone storage (/sonicWave) and enable folder-based albums.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => _startFolderOnboarding(
                  context,
                  playerProvider,
                  settingsProvider,
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  elevation: 0,
                ),
                child: const Text(
                  'Setup Folder Organization',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startFolderOnboarding(
    BuildContext context,
    PlayerProvider playerProvider,
    SettingsProvider settingsProvider,
  ) async {
    final volumes = await settingsProvider.getAvailableStorageVolumes();

    if (!context.mounted) return;

    // Detect if SD card is present
    StorageVolume? sdVolume;
    for (final v in volumes) {
      if (v.type == StorageType.sdCard) {
        sdVolume = v;
        break;
      }
    }

    StorageVolume? internalVolume;
    for (final v in volumes) {
      if (v.type == StorageType.deviceInternal) {
        internalVolume = v;
        break;
      }
    }
    internalVolume ??= const StorageVolume(
      label: 'Device Storage',
      path: '/storage/emulated/0',
      type: StorageType.deviceInternal,
      isAvailable: true,
    );

    final selectedVolume = sdVolume ?? internalVolume;

    final hasPermission = await StorageLocationService()
        .requestStoragePermission(targetType: selectedVolume.type);
    if (!context.mounted) return;
    if (!hasPermission) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Storage permissions are required to create a folder.'),
        ),
      );
      return;
    }

    if (!context.mounted) return;
    _showLoadingDialog(context, 'Migrating songs to folder...');

    final previousType = settingsProvider.storageType;
    final isMigrated = await playerProvider.migrateDownloadedFiles(
      previousType,
      selectedVolume.type,
      sdCardPath: selectedVolume.type == StorageType.sdCard
          ? selectedVolume.path
          : null,
    );

    if (!isMigrated) {
      if (context.mounted) {
        Navigator.pop(context); // Dismiss loading dialog
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: const Text(
              'Migration Failed',
              style: TextStyle(color: Colors.redAccent),
            ),
            content: const Text(
              'Could not create the target folder or migrate files. Please ensure your storage device is writeable and has appropriate permissions.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      return;
    }

    // Migration succeeded, now safe to change settings storage type
    await settingsProvider.setStorageType(
      selectedVolume.type,
      sdCardPath: selectedVolume.type == StorageType.sdCard
          ? selectedVolume.path
          : null,
    );

    if (context.mounted) {
      Navigator.pop(context); // Dismiss loading dialog
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Storage configured: ${selectedVolume.label}/sonicWave',
          ),
        ),
      );
    }

    await playerProvider.scanLocalSongs();
  }

  Widget _buildDownloadsTab() {
    return Consumer2<PlayerProvider, HomeProvider>(
      builder: (context, playerProvider, homeProvider, _) {
        final downloaded = playerProvider.downloadedSongs;
        final activeItems = playerProvider.activeDownloadItems;
        final isOffline = homeProvider.isOffline;

        // Split active items by status
        final downloadingItems = activeItems
            .where(
              (i) =>
                  i.status == DownloadStatus.downloading ||
                  i.status == DownloadStatus.retrying,
            )
            .toList();
        final pausedItems = activeItems
            .where((i) => i.status == DownloadStatus.paused)
            .toList();
        final queuedItems = activeItems
            .where((i) => i.status == DownloadStatus.queued)
            .toList();
        final failedItems = activeItems
            .where((i) => i.status == DownloadStatus.failed)
            .toList();
        final hasActiveDownloads = activeItems.isNotEmpty;

        return CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            // Actions row (cancel all / delete all)
            if (hasActiveDownloads || downloaded.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 16, 0),
                  child: Row(
                    children: [
                      const Spacer(),
                      if (hasActiveDownloads)
                        Container(
                          margin: const EdgeInsets.only(right: 4),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceVariant.withValues(
                              alpha: 0.6,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            tooltip: 'Cancel All',
                            icon: const Icon(
                              Icons.cancel_rounded,
                              color: Colors.redAccent,
                              size: 22,
                            ),
                            onPressed: () => _showCancelAllDownloadsDialog(
                              context,
                              playerProvider,
                            ),
                          ),
                        ),
                      if (downloaded.isNotEmpty)
                        Container(
                          decoration: BoxDecoration(
                            color: AppColors.surfaceVariant.withValues(
                              alpha: 0.6,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            tooltip: 'Delete All',
                            icon: const Icon(
                              Icons.delete_sweep_rounded,
                              color: Colors.redAccent,
                              size: 22,
                            ),
                            onPressed: () => _showDeleteAllDownloadsDialog(
                              context,
                              playerProvider,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

            // Storage & Network Status Header
            SliverToBoxAdapter(
              child: _buildDownloadsStatusHeader(
                context,
                playerProvider,
                isOffline,
                downloaded.length,
              ),
            ),

            // Network Offline Warning Banner
            if (isOffline && hasActiveDownloads)
              SliverToBoxAdapter(child: _buildOfflineDownloadBanner(context)),

            // 1. Downloading Items
            if (downloadingItems.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: _buildActiveDownloadsHeader(
                  context,
                  playerProvider,
                  downloadingItems.length + pausedItems.length,
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final item = downloadingItems[index];
                  return DownloadProgressCard(
                    key: ValueKey('dl_${item.song.videoId}'),
                    item: item,
                    playerProvider: playerProvider,
                  );
                }, childCount: downloadingItems.length),
              ),
            ],

            // 2. Paused Items
            if (pausedItems.isNotEmpty) ...[
              if (downloadingItems.isEmpty)
                SliverToBoxAdapter(
                  child: _buildActiveDownloadsHeader(
                    context,
                    playerProvider,
                    pausedItems.length,
                  ),
                ),
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final item = pausedItems[index];
                  return DownloadProgressCard(
                    key: ValueKey('dl_${item.song.videoId}'),
                    item: item,
                    playerProvider: playerProvider,
                  );
                }, childCount: pausedItems.length),
              ),
            ],

            // 3. Queued Items
            if (queuedItems.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: _buildDownloadsSectionHeader(
                  context,
                  '⏳ Queued',
                  '${queuedItems.length}',
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final item = queuedItems[index];
                  return QueuedDownloadTile(
                    key: ValueKey('q_${item.song.videoId}'),
                    item: item,
                    index: index,
                    playerProvider: playerProvider,
                  );
                }, childCount: queuedItems.length),
              ),
            ],

            // 4. Failed Items
            if (failedItems.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: _buildDownloadsSectionHeader(
                  context,
                  '❌ Failed',
                  '${failedItems.length}',
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final item = failedItems[index];
                  return FailedDownloadTile(
                    key: ValueKey('f_${item.song.videoId}'),
                    item: item,
                    playerProvider: playerProvider,
                  );
                }, childCount: failedItems.length),
              ),
            ],

            // 5. Downloaded Songs List
            if (downloaded.isEmpty && !hasActiveDownloads)
              SliverFillRemaining(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const PulsingIcon(
                        icon: Icons.download_for_offline_rounded,
                        size: 72,
                        color: AppColors.textTertiary,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'No Offline Downloads',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: AppColors.textTertiary,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Download songs to listen without internet',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.textTertiary.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else if (downloaded.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: _buildDownloadsSectionHeader(
                  context,
                  '📥 Downloaded Songs',
                  '${downloaded.length}',
                ),
              ),
              SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  return DownloadedSongTile(
                    key: ValueKey('d_${downloaded[index].videoId}'),
                    song: downloaded[index],
                    index: index,
                    playerProvider: playerProvider,
                    allDownloaded: downloaded,
                  );
                }, childCount: downloaded.length),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 140)),
          ],
        );
      },
    );
  }

  Widget _buildDownloadsStatusHeader(
    BuildContext context,
    PlayerProvider provider,
    bool isOffline,
    int downloadCount,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        children: [
          Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: isOffline
                      ? Colors.redAccent.withValues(alpha: 0.15)
                      : AppColors.success.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isOffline
                        ? Colors.redAccent.withValues(alpha: 0.3)
                        : AppColors.success.withValues(alpha: 0.3),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: isOffline ? Colors.redAccent : AppColors.success,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isOffline ? 'Offline' : 'Online',
                      style: TextStyle(
                        color: isOffline ? Colors.redAccent : AppColors.success,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.download_done_rounded,
                      size: 14,
                      color: AppColors.textTertiary,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '$downloadCount songs',
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.storage_rounded,
                      size: 14,
                      color: AppColors.textTertiary,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      provider.formattedStorageUsed,
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOfflineDownloadBanner(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.amber.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.amber.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
        child: const Row(
          children: [
            Icon(Icons.wifi_off_rounded, color: Colors.amber, size: 18),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'You\'re offline — Active downloads are paused',
                style: TextStyle(
                  color: Colors.amber,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadsSectionHeader(
    BuildContext context,
    String title,
    String count,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Row(
        children: [
          Text(title, style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              count,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// "Active Downloads" header with the live combined speed of all tasks.
  Widget _buildActiveDownloadsHeader(
    BuildContext context,
    PlayerProvider provider,
    int count,
  ) {
    final totalSpeed = provider.formattedTotalDownloadSpeed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Row(
        children: [
          Text(
            '⚡ Active Downloads',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const Spacer(),
          if (totalSpeed.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.success.withValues(alpha: 0.3),
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.speed_rounded,
                    size: 13,
                    color: AppColors.success,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    totalSpeed,
                    style: const TextStyle(
                      color: AppColors.success,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _showCancelAllDownloadsDialog(
    BuildContext context,
    PlayerProvider provider,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Cancel All Downloads?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'This will cancel all active and queued downloads. This action cannot be undone.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () {
              provider.cancelAllDownloads();
              Navigator.pop(ctx);
            },
            child: const Text(
              'Cancel All',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }

  void _showDeleteAllDownloadsDialog(
    BuildContext context,
    PlayerProvider provider,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Delete All Downloads?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'All downloaded songs will be permanently removed from your device.',
          style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () {
              provider.deleteAllDownloads();
              Navigator.pop(ctx);
            },
            child: const Text(
              'Delete All',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }

  void _showLoadingDialog(BuildContext context, String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          content: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: AppColors.glassBorder.withValues(alpha: 0.15),
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  blurRadius: 40,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Animated pulsing ring around the indicator
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 1500),
                  builder: (context, value, child) {
                    return Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppColors.primary.withValues(
                            alpha: 0.15 + 0.1 * value,
                          ),
                          width: 3,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(
                              alpha: 0.1 + 0.05 * value,
                            ),
                            blurRadius: 20 + 10 * value,
                            spreadRadius: 2 * value,
                          ),
                        ],
                      ),
                      child: const Center(
                        child: SizedBox(
                          width: 36,
                          height: 36,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            valueColor: AlwaysStoppedAnimation(
                              AppColors.primaryLight,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 24),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Please wait...',
                  style: TextStyle(
                    color: AppColors.textTertiary.withValues(alpha: 0.6),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _promptAddCustomCategory(
    BuildContext context,
    List<AiProposedAlbum> proposedAlbums,
    List<bool> albumSelection,
    StateSetter setSheetState,
  ) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Add Custom Category',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'e.g. Party Hits, Workout, Classical...',
            hintStyle: const TextStyle(
              color: AppColors.textTertiary,
              fontSize: 12,
            ),
            filled: true,
            fillColor: AppColors.surfaceVariant.withValues(alpha: 0.4),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                setSheetState(() {
                  proposedAlbums.add(
                    AiProposedAlbum(
                      name: name,
                      description: 'Custom user category',
                      songIds: [],
                      source: 'Custom',
                    ),
                  );
                  albumSelection.add(true);
                });
                Navigator.pop(ctx);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
            ),
            child: const Text('Add Category'),
          ),
        ],
      ),
    );
  }

  void _showAiConfirmationSheet(
    BuildContext context,
    List<AiProposedAlbum> proposedAlbums,
    List<Song> songs,
    PlayerProvider provider,
  ) {
    final List<bool> albumSelection = List.filled(proposedAlbums.length, true);
    final List<Color> themeColors = [
      Colors.purpleAccent,
      Colors.cyanAccent,
      Colors.amberAccent,
      Colors.lightGreenAccent,
      Colors.pinkAccent,
      Colors.deepOrangeAccent,
      Colors.blueAccent,
    ];

    String activeFilter = 'All'; // 'All', 'High Match', 'Custom'

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final screenHeight = MediaQuery.of(sheetContext).size.height;
            final totalSongsCount = proposedAlbums.fold<int>(
              0,
              (sum, item) => sum + item.songIds.length,
            );
            final selectedCount = albumSelection.where((b) => b).length;

            // Filter logic
            final indexedProposals = List.generate(
              proposedAlbums.length,
              (i) => MapEntry(i, proposedAlbums[i]),
            );
            final filteredEntries = indexedProposals.where((entry) {
              if (activeFilter == 'High Match') {
                return entry.value.confidence >= 0.7;
              } else if (activeFilter == 'Custom') {
                return entry.value.source == 'Your Category' ||
                    entry.value.source == 'Unassigned';
              }
              return true;
            }).toList();

            return Container(
              height: screenHeight * 0.90,
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(alpha: 0.98),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border.all(color: AppColors.glassBorder, width: 0.8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.purpleAccent.withValues(alpha: 0.15),
                    blurRadius: 30,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Column(
                children: [
                  // Top Drag Handle
                  Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 8),
                    width: 42,
                    height: 4.5,
                    decoration: BoxDecoration(
                      color: AppColors.textTertiary.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),

                  // Header Section
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  colors: [
                                    Theme.of(context).colorScheme.primary,
                                    Colors.purpleAccent,
                                  ],
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.4),
                                    blurRadius: 14,
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.auto_awesome_rounded,
                                color: Colors.white,
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'AI ORGANIZER COMPLETED',
                                    style: GoogleFonts.outfit(
                                      color: Colors.white,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 1.2,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${proposedAlbums.length} Proposed Albums • $totalSongsCount Tracks Organized',
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // Quick Add Category Button
                            ElevatedButton.icon(
                              onPressed: () => _promptAddCustomCategory(
                                sheetContext,
                                proposedAlbums,
                                albumSelection,
                                setSheetState,
                              ),
                              icon: const Icon(Icons.add_rounded, size: 16),
                              label: const Text(
                                'Add Category',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.2),
                                foregroundColor: Theme.of(
                                  context,
                                ).colorScheme.primary,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 14),

                        // Navigation Filter Chips & Select All Toggle
                        Row(
                          children: [
                            // Select All / Deselect All Toggle Chip
                            GestureDetector(
                              onTap: () {
                                setSheetState(() {
                                  final allSelected = albumSelection.every(
                                    (b) => b,
                                  );
                                  for (
                                    int i = 0;
                                    i < albumSelection.length;
                                    i++
                                  ) {
                                    albumSelection[i] = !allSelected;
                                  }
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.surfaceVariant.withValues(
                                    alpha: 0.4,
                                  ),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.1),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      albumSelection.every((b) => b)
                                          ? Icons.check_box_rounded
                                          : Icons
                                                .indeterminate_check_box_rounded,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      albumSelection.every((b) => b)
                                          ? 'Deselect All'
                                          : 'Select All',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                physics: const BouncingScrollPhysics(),
                                child: Row(
                                  children: ['All', 'High Match', 'Custom'].map(
                                    (filterName) {
                                      final isActive =
                                          activeFilter == filterName;
                                      return Padding(
                                        padding: const EdgeInsets.only(
                                          right: 6,
                                        ),
                                        child: ChoiceChip(
                                          label: Text(filterName),
                                          selected: isActive,
                                          onSelected: (selected) {
                                            if (selected) {
                                              setSheetState(() {
                                                activeFilter = filterName;
                                              });
                                            }
                                          },
                                          selectedColor: Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withValues(alpha: 0.3),
                                          backgroundColor: AppColors
                                              .surfaceVariant
                                              .withValues(alpha: 0.2),
                                          labelStyle: TextStyle(
                                            color: isActive
                                                ? Colors.white
                                                : AppColors.textTertiary,
                                            fontSize: 11,
                                            fontWeight: isActive
                                                ? FontWeight.bold
                                                : FontWeight.normal,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ).toList(),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const Divider(color: AppColors.divider, height: 1),

                  // Proposed Albums List View
                  Expanded(
                    child: filteredEntries.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.filter_alt_off_rounded,
                                  size: 40,
                                  color: AppColors.textTertiary.withValues(
                                    alpha: 0.5,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'No categories match this filter',
                                  style: TextStyle(
                                    color: AppColors.textTertiary,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            physics: const BouncingScrollPhysics(),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            itemCount: filteredEntries.length,
                            itemBuilder: (listCtx, index) {
                              final entry = filteredEntries[index];
                              final albumIdx = entry.key;
                              final album = entry.value;
                              final isSelected = albumSelection[albumIdx];
                              final categoryColor =
                                  themeColors[albumIdx % themeColors.length];

                              final albumSongs = album.songIds.map((id) {
                                return songs.firstWhere(
                                  (s) => s.videoId == id,
                                  orElse: () => Song(
                                    id: id,
                                    title: 'Unknown Song',
                                    artist: 'Unknown Artist',
                                    thumbnailUrl: '',
                                    highResThumbnailUrl: '',
                                    duration: Duration.zero,
                                    videoId: id,
                                  ),
                                );
                              }).toList();

                              return _StaggeredListSlideIn(
                                index: albumIdx,
                                child: Container(
                                  margin: const EdgeInsets.symmetric(
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: categoryColor.withValues(
                                      alpha: isSelected ? 0.08 : 0.02,
                                    ),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: isSelected
                                          ? categoryColor.withValues(alpha: 0.5)
                                          : Colors.white.withValues(
                                              alpha: 0.08,
                                            ),
                                      width: isSelected ? 1.2 : 0.8,
                                    ),
                                    boxShadow: isSelected
                                        ? [
                                            BoxShadow(
                                              color: categoryColor.withValues(
                                                alpha: 0.1,
                                              ),
                                              blurRadius: 16,
                                              spreadRadius: 1,
                                            ),
                                          ]
                                        : [],
                                  ),
                                  child: Theme(
                                    data: Theme.of(context).copyWith(
                                      dividerColor: Colors.transparent,
                                    ),
                                    child: ExpansionTile(
                                      initiallyExpanded: true,
                                      iconColor: categoryColor,
                                      collapsedIconColor: Colors.white70,
                                      leading: Checkbox(
                                        activeColor: categoryColor,
                                        checkColor: Colors.black,
                                        value: isSelected,
                                        onChanged: (val) {
                                          setSheetState(() {
                                            albumSelection[albumIdx] =
                                                val ?? false;
                                          });
                                        },
                                      ),
                                      title: Row(
                                        children: [
                                          Expanded(
                                            child: TextField(
                                              controller:
                                                  TextEditingController(
                                                      text: album.name,
                                                    )
                                                    ..selection =
                                                        TextSelection.fromPosition(
                                                          TextPosition(
                                                            offset: album
                                                                .name
                                                                .length,
                                                          ),
                                                        ),
                                              style: TextStyle(
                                                color: isSelected
                                                    ? categoryColor
                                                    : Colors.white,
                                                fontSize: 14,
                                                fontWeight: FontWeight.bold,
                                              ),
                                              decoration: const InputDecoration(
                                                border: InputBorder.none,
                                                isDense: true,
                                                hintText: 'Category Name',
                                                hintStyle: TextStyle(
                                                  color: AppColors.textTertiary,
                                                ),
                                              ),
                                              onChanged: (val) {
                                                album.name = val;
                                              },
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: categoryColor.withValues(
                                                alpha: 0.2,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              album.source.isNotEmpty
                                                  ? album.source
                                                  : '${albumSongs.length} tracks',
                                              style: TextStyle(
                                                color: categoryColor,
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      subtitle: TextField(
                                        controller:
                                            TextEditingController(
                                                text: album.description,
                                              )
                                              ..selection =
                                                  TextSelection.fromPosition(
                                                    TextPosition(
                                                      offset: album
                                                          .description
                                                          .length,
                                                    ),
                                                  ),
                                        style: const TextStyle(
                                          color: AppColors.textTertiary,
                                          fontSize: 11,
                                        ),
                                        decoration: const InputDecoration(
                                          border: InputBorder.none,
                                          isDense: true,
                                          hintText: 'Category Description',
                                          hintStyle: TextStyle(
                                            color: AppColors.textTertiary,
                                          ),
                                        ),
                                        onChanged: (val) {
                                          album.description = val;
                                        },
                                      ),
                                      childrenPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 6,
                                          ),
                                      children: [
                                        const Divider(color: Colors.white10),
                                        if (albumSongs.isEmpty)
                                          const Padding(
                                            padding: EdgeInsets.symmetric(
                                              vertical: 10,
                                            ),
                                            child: Text(
                                              'No songs in this category (tap Move icon on another song to transfer)',
                                              style: TextStyle(
                                                color: AppColors.textTertiary,
                                                fontSize: 11,
                                              ),
                                            ),
                                          )
                                        else
                                          Column(
                                            children: albumSongs.map((song) {
                                              return Container(
                                                margin:
                                                    const EdgeInsets.symmetric(
                                                      vertical: 3,
                                                    ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                      vertical: 6,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: AppColors
                                                      .surfaceVariant
                                                      .withValues(alpha: 0.3),
                                                  borderRadius:
                                                      BorderRadius.circular(10),
                                                ),
                                                child: Row(
                                                  children: [
                                                    Icon(
                                                      Icons.music_note_rounded,
                                                      color: categoryColor,
                                                      size: 16,
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Expanded(
                                                      child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        children: [
                                                          Text(
                                                            song.title,
                                                            style:
                                                                const TextStyle(
                                                                  color: Colors
                                                                      .white,
                                                                  fontSize: 12,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold,
                                                                ),
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                          Text(
                                                            song.artist,
                                                            style: const TextStyle(
                                                              color: AppColors
                                                                  .textTertiary,
                                                              fontSize: 10,
                                                            ),
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                    // Easy Move Button with Target Picker Popup
                                                    PopupMenuButton<int>(
                                                      icon: Icon(
                                                        Icons
                                                            .swap_horiz_rounded,
                                                        color: categoryColor,
                                                        size: 20,
                                                      ),
                                                      tooltip:
                                                          'Move song to another category',
                                                      color: AppColors.surface,
                                                      shape: RoundedRectangleBorder(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              14,
                                                            ),
                                                      ),
                                                      onSelected: (targetIdx) {
                                                        setSheetState(() {
                                                          album.songIds.remove(
                                                            song.videoId,
                                                          );
                                                          proposedAlbums[targetIdx]
                                                              .songIds
                                                              .add(
                                                                song.videoId,
                                                              );
                                                        });
                                                        ScaffoldMessenger.of(
                                                          context,
                                                        ).showSnackBar(
                                                          SnackBar(
                                                            content: Text(
                                                              'Moved "${song.title}" to "${proposedAlbums[targetIdx].name}"',
                                                            ),
                                                            duration:
                                                                const Duration(
                                                                  seconds: 2,
                                                                ),
                                                          ),
                                                        );
                                                      },
                                                      itemBuilder: (popCtx) {
                                                        return List.generate(proposedAlbums.length, (
                                                          idx,
                                                        ) {
                                                          final targetColor =
                                                              themeColors[idx %
                                                                  themeColors
                                                                      .length];
                                                          return PopupMenuItem<
                                                            int
                                                          >(
                                                            value: idx,
                                                            enabled:
                                                                idx != albumIdx,
                                                            child: Row(
                                                              children: [
                                                                Container(
                                                                  width: 8,
                                                                  height: 8,
                                                                  decoration: BoxDecoration(
                                                                    color:
                                                                        targetColor,
                                                                    shape: BoxShape
                                                                        .circle,
                                                                  ),
                                                                ),
                                                                const SizedBox(
                                                                  width: 8,
                                                                ),
                                                                Expanded(
                                                                  child: Text(
                                                                    proposedAlbums[idx]
                                                                        .name,
                                                                    style: TextStyle(
                                                                      color:
                                                                          idx ==
                                                                              albumIdx
                                                                          ? AppColors.textTertiary
                                                                          : Colors.white,
                                                                      fontSize:
                                                                          12,
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .bold,
                                                                    ),
                                                                    maxLines: 1,
                                                                    overflow:
                                                                        TextOverflow
                                                                            .ellipsis,
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          );
                                                        });
                                                      },
                                                    ),
                                                    // Remove from Category Button
                                                    IconButton(
                                                      icon: const Icon(
                                                        Icons.close_rounded,
                                                        color: Colors.redAccent,
                                                        size: 16,
                                                      ),
                                                      onPressed: () {
                                                        setSheetState(() {
                                                          album.songIds.remove(
                                                            song.videoId,
                                                          );
                                                        });
                                                      },
                                                    ),
                                                  ],
                                                ),
                                              );
                                            }).toList(),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),

                  const Divider(color: AppColors.divider, height: 1),

                  // Bottom Fixed Action Footer
                  Padding(
                    padding: EdgeInsets.only(
                      left: 20,
                      right: 20,
                      top: 14,
                      bottom: 14 + MediaQuery.of(sheetContext).padding.bottom,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(sheetContext),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.white24),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: const Text(
                              'Cancel',
                              style: TextStyle(color: Colors.white70),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton.icon(
                            onPressed: selectedCount == 0
                                ? null
                                : () async {
                                    _showLoadingDialog(
                                      context,
                                      'Organizing tracks into album folders...\nExecuting secure file move...',
                                    );
                                    int albumsCreated = 0;
                                    int albumsUpdated = 0;
                                    try {
                                      for (
                                        int i = 0;
                                        i < proposedAlbums.length;
                                        i++
                                      ) {
                                        if (albumSelection[i]) {
                                          final proposal = proposedAlbums[i];
                                          if (proposal.name.trim().isEmpty ||
                                              proposal.songIds.isEmpty) {
                                            continue;
                                          }

                                          final albumSongs = proposal.songIds
                                              .map((id) {
                                                return songs.firstWhere(
                                                  (s) => s.videoId == id,
                                                  orElse: () => Song(
                                                    id: id,
                                                    title: 'Unknown Song',
                                                    artist: 'Unknown Artist',
                                                    thumbnailUrl: '',
                                                    highResThumbnailUrl: '',
                                                    duration: Duration.zero,
                                                    videoId: id,
                                                  ),
                                                );
                                              })
                                              .toList();

                                          if (proposal.existingAlbumId !=
                                              null) {
                                            final existing = provider.albums
                                                .firstWhere(
                                                  (a) =>
                                                      a.id ==
                                                      proposal.existingAlbumId,
                                                );
                                            final List<Song> merged = List.from(
                                              existing.songs,
                                            );
                                            for (final s in albumSongs) {
                                              if (!merged.any(
                                                (item) =>
                                                    item.videoId == s.videoId,
                                              )) {
                                                merged.add(s);
                                              }
                                            }
                                            await provider.updateAlbumSongs(
                                              existing.id,
                                              merged,
                                            );
                                            albumsUpdated++;
                                          } else {
                                            final newAlbum = await provider
                                                .createAlbum(
                                                  proposal.name.trim(),
                                                );
                                            await provider.updateAlbumSongs(
                                              newAlbum.id,
                                              albumSongs,
                                            );
                                            albumsCreated++;
                                          }
                                        }
                                      }
                                    } catch (e) {
                                      debugPrint(
                                        'Error processing Smart Organizer albums: $e',
                                      );
                                    }

                                    if (context.mounted) {
                                      Navigator.pop(
                                        context,
                                      ); // Dismiss loading dialog
                                    }
                                    if (sheetContext.mounted) {
                                      Navigator.pop(
                                        sheetContext,
                                      ); // Dismiss sheet
                                    }
                                    if (!context.mounted) return;

                                    String msg = '';
                                    if (albumsCreated > 0 &&
                                        albumsUpdated > 0) {
                                      msg =
                                          'Created $albumsCreated new and updated $albumsUpdated existing albums!';
                                    } else if (albumsCreated > 0) {
                                      msg =
                                          'Successfully created $albumsCreated albums!';
                                    } else if (albumsUpdated > 0) {
                                      msg =
                                          'Successfully updated $albumsUpdated existing albums!';
                                    } else {
                                      msg = 'No actions performed.';
                                    }
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(msg),
                                        backgroundColor: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                      ),
                                    );
                                  },
                            icon: const Icon(Icons.check_rounded, size: 18),
                            label: Text(
                              'Apply AI Organization ($selectedCount)',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.primary,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              elevation: 4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showMoveSongsToAppFolderDialog(
    BuildContext context,
    List<Song> localSongs,
    PlayerProvider provider,
  ) {
    final storageService = StorageLocationService();

    // Filter to only get the external ones
    final externalSongs = localSongs.where((s) {
      if (!s.isLocalFile || s.filePath == null) return false;
      return !storageService.isFileInAppFolderSync(s.filePath!);
    }).toList();

    if (externalSongs.isEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text(
            'All Songs in App Folder',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'All scanned local songs are already located inside the app-managed directory.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final controller = TextEditingController();
    bool useAlbumFolder = false;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: AppColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: const Text(
                'Move to SonicWave Folder',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Found ${externalSongs.length} local song(s) outside the app folder. Move them to your app-managed folder?',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Checkbox(
                        value: useAlbumFolder,
                        onChanged: (val) {
                          setState(() {
                            useAlbumFolder = val ?? false;
                          });
                        },
                      ),
                      const Expanded(
                        child: Text(
                          'Organize into a subfolder (Album)',
                          style: TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                  if (useAlbumFolder) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: controller,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Enter album / folder name...',
                        hintStyle: const TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 12,
                        ),
                        filled: true,
                        fillColor: AppColors.surfaceVariant.withValues(
                          alpha: 0.4,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final albumName = useAlbumFolder
                        ? controller.text.trim()
                        : null;
                    if (useAlbumFolder &&
                        (albumName == null || albumName.isEmpty)) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Please enter a folder name'),
                        ),
                      );
                      return;
                    }
                    Navigator.pop(ctx);

                    // Show progress indicator
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (pCtx) =>
                          const Center(child: CircularProgressIndicator()),
                    );

                    final moved = await provider.moveScannedSongsToAppFolder(
                      externalSongs,
                      albumName: albumName,
                    );

                    if (context.mounted) {
                      Navigator.pop(context); // Dismiss progress
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Successfully moved ${moved.length} song(s)',
                          ),
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primary,
                        ),
                      );
                    }
                  },
                  child: const Text(
                    'Move Now',
                    style: TextStyle(color: AppColors.primary),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _startAiCategorizationFlow(
    BuildContext context,
    List<Song> songs,
    PlayerProvider provider,
  ) async {
    final unclassifiedSongs = songs.where((s) {
      return !provider.albums.any(
        (album) =>
            album.songs.any((albumSong) => albumSong.videoId == s.videoId),
      );
    }).toList();

    if (unclassifiedSongs.isEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text(
            'All Songs Categorized',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'All scanned local songs are already added to one or more albums!',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    _showLoadingDialog(
      context,
      'Scanning MusicBrainz database & analyzing local files to organize albums...',
    );
    try {
      final service = AiCategorizationService();
      final result = await service.categorizeSongs(
        unclassifiedSongs,
        provider.albums,
      );

      if (!context.mounted) return;
      Navigator.pop(context); // Dismiss loading dialog

      if (result.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not categorize local songs.')),
        );
        return;
      }

      _showAiConfirmationSheet(context, result, unclassifiedSongs, provider);
    } catch (e) {
      if (!context.mounted) return;
      Navigator.pop(context); // Dismiss loading dialog
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error organizing: $e')));
    }
  }

  Widget _buildGreetingWidget(BuildContext context) {
    final hour = DateTime.now().hour;
    String greeting;
    IconData icon;
    Color iconColor;
    String quote;

    final quotes = [
      "Where words fail, music speaks.",
      "Music is the shorthand of emotion.",
      "Life is one grand sweet song, so start the music.",
      "Without music, life would be a mistake.",
      "Music is the wine that fills the cup of silence.",
      "One good thing about music, when it hits you, you feel no pain.",
    ];

    if (hour < 12) {
      greeting = 'Good Morning';
      icon = Icons.light_mode_rounded;
      iconColor = Colors.amber;
      quote = "Rise and shine! Start your day with some positive vibes.";
    } else if (hour < 17) {
      greeting = 'Good Afternoon';
      icon = Icons.wb_sunny_rounded;
      iconColor = Colors.orangeAccent;
      quote = "Stay productive! Let background music fuel your focus.";
    } else if (hour < 21) {
      greeting = 'Good Evening';
      icon = Icons.wb_twilight_rounded;
      iconColor = Colors.deepOrangeAccent;
      quote = "Unwind and relax. Enjoy some cozy evening melodies.";
    } else {
      greeting = 'Good Night';
      icon = Icons.dark_mode_rounded;
      iconColor = Colors.lightBlueAccent;
      quote = "Rest well. Drift off to sleep with a soothing low-fi playlist.";
    }

    return GestureDetector(
      onTap: () {
        final randQuote = quotes[math.Random().nextInt(quotes.length)];
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppColors.surfaceVariant,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            content: Row(
              children: [
                const Icon(Icons.music_note_rounded, color: AppColors.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '"$randQuote"\n— $quote',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: Colors.white,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            greeting,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppColors.textSecondary,
              letterSpacing: 0.5,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 6),
          Icon(icon, color: iconColor, size: 14),
        ],
      ),
    );
  }

  /// Shows a picker dialog with all albums except the current one.
  Future<UserAlbum?> _showAlbumPickerForMove(
    BuildContext context,
    PlayerProvider provider,
    String excludeAlbumId,
  ) async {
    final albums = provider.albums
        .where((a) => a.id != excludeAlbumId)
        .toList();
    if (albums.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No other albums available. Create one first.'),
          ),
        );
      }
      return null;
    }
    return showModalBottomSheet<UserAlbum>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textTertiary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Icon(
                      Icons.drive_file_move_rounded,
                      color: AppColors.primaryLight,
                      size: 22,
                    ),
                    SizedBox(width: 10),
                    Text(
                      'Move to Album',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              const Divider(color: AppColors.divider, height: 1),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.4,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: albums.length,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemBuilder: (ctx, index) {
                    final album = albums[index];
                    return ListTile(
                      leading: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          gradient: LinearGradient(
                            colors: [
                              AppColors.primary.withValues(alpha: 0.3),
                              AppColors.secondary.withValues(alpha: 0.15),
                            ],
                          ),
                        ),
                        child: Center(
                          child: album.isFolderBased
                              ? Icon(
                                  Icons.folder_rounded,
                                  color: Colors.amber.withValues(alpha: 0.9),
                                  size: 20,
                                )
                              : const Icon(
                                  Icons.album_rounded,
                                  color: AppColors.primaryLight,
                                  size: 20,
                                ),
                        ),
                      ),
                      title: Text(
                        album.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        '${album.songCount} tracks • ${album.formattedTotalSize}',
                        style: const TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: 11,
                        ),
                      ),
                      trailing: Icon(
                        Icons.arrow_forward_ios_rounded,
                        color: AppColors.textTertiary.withValues(alpha: 0.5),
                        size: 14,
                      ),
                      onTap: () => Navigator.pop(ctx, album),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<_HomeScreenMoveResult?> _promptMoveType(BuildContext context) async {
    return showDialog<_HomeScreenMoveResult>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        contentPadding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.swap_horiz_rounded,
              color: AppColors.primaryLight,
              size: 36,
            ),
            const SizedBox(height: 12),
            const Text(
              'Choose Storage Operation',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 20),
            // Make a Copy option card
            _buildMoveOptionCard(
              ctx,
              icon: Icons.copy_rounded,
              title: 'Make a Copy',
              subtitle:
                  'Duplicates audio file into target album folder while leaving original file intact.',
              color: Colors.cyanAccent,
              onTap: () => Navigator.pop(
                ctx,
                const _HomeScreenMoveResult(
                  physicalMove: true,
                  isCopyMode: true,
                ),
              ),
            ),
            const SizedBox(height: 10),
            // Permanently Move option card
            _buildMoveOptionCard(
              ctx,
              icon: Icons.drive_file_move_rounded,
              title: 'Permanently Move',
              subtitle:
                  'Physically transfers original audio file on disk into target album\'s folder.',
              color: AppColors.primary,
              onTap: () => Navigator.pop(
                ctx,
                const _HomeScreenMoveResult(
                  physicalMove: true,
                  isCopyMode: false,
                ),
              ),
            ),
            const SizedBox(height: 10),
            // In-App Bookmark option card
            _buildMoveOptionCard(
              ctx,
              icon: Icons.bookmark_rounded,
              title: 'In-App Bookmark',
              subtitle:
                  'Reorganize album tags inside app memory only without moving disk files.',
              color: AppColors.secondary,
              onTap: () => Navigator.pop(
                ctx,
                const _HomeScreenMoveResult(
                  physicalMove: false,
                  isCopyMode: false,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMoveOptionCard(
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
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withValues(alpha: 0.2), width: 1),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: color,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: AppColors.textTertiary,
                        fontSize: 10,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_rounded,
                color: color.withValues(alpha: 0.5),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDeleteSongDialog(
    BuildContext context,
    Song song,
    UserAlbum album,
    PlayerProvider provider,
    VoidCallback onDeleted,
  ) {
    final isPhysical = album.isFolderBased && song.filePath != null;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        contentPadding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Warning icon with red glow
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.redAccent.withValues(alpha: 0.1),
                boxShadow: [
                  BoxShadow(
                    color: Colors.redAccent.withValues(alpha: 0.15),
                    blurRadius: 24,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(
                Icons.warning_amber_rounded,
                color: Colors.redAccent,
                size: 32,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Remove Song?',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '"${song.title}"',
              style: const TextStyle(
                color: AppColors.primaryLight,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            // Cancel
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(ctx),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(
                    color: AppColors.textTertiary.withValues(alpha: 0.3),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text(
                  'Cancel',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Remove from album only
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  final updatedSongs = album.songs
                      .where((s) => s.videoId != song.videoId)
                      .toList();
                  await provider.updateAlbumSongs(album.id, updatedSongs);
                  onDeleted();
                },
                icon: const Icon(Icons.bookmark_remove_rounded, size: 16),
                label: const Text(
                  'Remove from Album',
                  style: TextStyle(fontSize: 13),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber.withValues(alpha: 0.15),
                  foregroundColor: Colors.amber,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            if (isPhysical) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await provider.deleteSongPermanently(song);
                    onDeleted();
                  },
                  icon: const Icon(Icons.delete_forever_rounded, size: 16),
                  label: const Text(
                    'Delete Permanently',
                    style: TextStyle(fontSize: 13),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent.withValues(alpha: 0.15),
                    foregroundColor: Colors.redAccent,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LivePulseDot extends StatefulWidget {
  const _LivePulseDot();

  @override
  State<_LivePulseDot> createState() => _LivePulseDotState();
}

class _LivePulseDotState extends State<_LivePulseDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return SizedBox(
          width: 16,
          height: 16,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Expanding ripple
              Container(
                width: 6 + 10 * _controller.value,
                height: 6 + 10 * _controller.value,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.success.withValues(
                    alpha: 0.4 * (1 - _controller.value),
                  ),
                ),
              ),
              Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.success,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TrendingCard extends StatefulWidget {
  final Song song;
  final int index;
  final VoidCallback onTap;

  const _TrendingCard({
    required this.song,
    required this.index,
    required this.onTap,
  });

  @override
  State<_TrendingCard> createState() => _TrendingCardState();
}

class _TrendingCardState extends State<_TrendingCard>
    with TickerProviderStateMixin {
  late AnimationController _hoverController;
  late AnimationController _entryController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _entryFade;
  late Animation<Offset> _entrySlide;

  @override
  void initState() {
    super.initState();
    _hoverController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _hoverController, curve: Curves.easeInOut),
    );

    // Staggered entrance: fade + slide from the right
    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _entryFade = CurvedAnimation(
      parent: _entryController,
      curve: Curves.easeOut,
    );
    _entrySlide = Tween<Offset>(begin: const Offset(0.25, 0), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _entryController, curve: Curves.easeOutCubic),
        );
    Future.delayed(
      Duration(milliseconds: math.min(widget.index * 70, 500)),
      () {
        if (mounted) _entryController.forward();
      },
    );
  }

  @override
  void dispose() {
    _hoverController.dispose();
    _entryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return SlideTransition(
      position: _entrySlide,
      child: FadeTransition(
        opacity: _entryFade,
        child: GestureDetector(
          onTapDown: (_) => _hoverController.forward(),
          onTapUp: (_) {
            _hoverController.reverse();
            widget.onTap();
          },
          onTapCancel: () => _hoverController.reverse(),
          child: AnimatedBuilder(
            animation: _scaleAnimation,
            builder: (context, child) {
              return Transform.scale(
                scale: _scaleAnimation.value,
                child: child,
              );
            },
            child: Container(
              width: 190,
              margin: const EdgeInsets.only(right: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    SongAlbumArt(
                      song: widget.song,
                      width: 190,
                      height: 250,
                      borderRadius: 22,
                    ),
                    // Bottom gradient scrim so text stays readable
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0.45, 0.75, 1.0],
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.55),
                            Colors.black.withValues(alpha: 0.88),
                          ],
                        ),
                      ),
                    ),
                    // Rank badge
                    Positioned(
                      top: 10,
                      left: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [primary, AppColors.secondary],
                          ),
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(
                              color: primary.withValues(alpha: 0.5),
                              blurRadius: 10,
                            ),
                          ],
                        ),
                        child: Text(
                          '#${widget.index + 1}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    // Title, artist & play button
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 12,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  widget.song.title,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    height: 1.2,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  widget.song.artist,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.white.withValues(alpha: 0.75),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: primary,
                              boxShadow: [
                                BoxShadow(
                                  color: primary.withValues(alpha: 0.5),
                                  blurRadius: 12,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 24,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SectionDetailScreen extends StatefulWidget {
  final String title;
  final List<Song> songs;

  const SectionDetailScreen({
    super.key,
    required this.title,
    required this.songs,
  });

  @override
  State<SectionDetailScreen> createState() => _SectionDetailScreenState();
}

class _SectionDetailScreenState extends State<SectionDetailScreen> {
  late List<Song> _songs;
  bool _isLoadingMore = false;

  @override
  void initState() {
    super.initState();
    _songs = List.from(widget.songs);
    _loadMoreSongs();
  }

  Future<void> _loadMoreSongs() async {
    final homeProvider = context.read<HomeProvider>();
    if (homeProvider.isOffline) return;

    setState(() {
      _isLoadingMore = true;
    });

    try {
      final ytService = YouTubeService();
      final archiveService = ArchiveOrgService();
      final query = widget.title == 'Trending Now'
          ? 'trending music hits'
          : widget.title;

      final ytFuture = ytService.searchSongs(query, maxResults: 25);
      final archiveFuture = archiveService.searchSongs(query, maxResults: 10);

      final searchResults = await Future.wait([ytFuture, archiveFuture]);
      final ytResults = searchResults[0];
      final archiveResults = searchResults[1];
      final results = [...ytResults, ...archiveResults];

      if (mounted) {
        setState(() {
          final existingIds = _songs.map((s) => s.videoId).toSet();
          for (final song in results) {
            if (!existingIds.contains(song.videoId)) {
              _songs.add(song);
            }
          }
          _isLoadingMore = false;
        });
      }
    } catch (e) {
      debugPrint('Failed to load more songs: $e');
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.backgroundGradient),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.outfit(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (_isLoadingMore)
                      const Padding(
                        padding: EdgeInsets.only(right: 12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(Colors.white30),
                          ),
                        ),
                      ),
                    IconButton(
                      icon: const Icon(
                        Icons.shuffle_rounded,
                        color: Colors.white70,
                        size: 22,
                      ),
                      onPressed: () {
                        if (_songs.isNotEmpty) {
                          final provider = context.read<PlayerProvider>();
                          provider.playPlaylist(_songs);
                          provider.toggleShuffle();
                        }
                      },
                    ),
                  ],
                ),
              ),

              // Song List
              Expanded(
                child: _songs.isEmpty
                    ? const Center(
                        child: Text(
                          'No songs in this section',
                          style: TextStyle(color: Colors.white30),
                        ),
                      )
                    : ListView.builder(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 100),
                        itemCount: _songs.length,
                        itemBuilder: (context, index) {
                          final song = _songs[index];
                          return SongTile(
                            song: song,
                            index: index,
                            onTap: () {
                              context.read<PlayerProvider>().playPlaylist(
                                _songs,
                                startIndex: index,
                              );
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AnimatedPressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;

  const _AnimatedPressScale({required this.child, required this.onTap});

  @override
  State<_AnimatedPressScale> createState() => _AnimatedPressScaleState();
}

class _AnimatedPressScaleState extends State<_AnimatedPressScale> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.95),
      onTapUp: (_) {
        setState(() => _scale = 1.0);
        widget.onTap();
      },
      onTapCancel: () => setState(() => _scale = 1.0),
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeInOut,
        child: widget.child,
      ),
    );
  }
}

class _StaggeredListSlideIn extends StatefulWidget {
  final int index;
  final Widget child;

  const _StaggeredListSlideIn({required this.index, required this.child});

  @override
  State<_StaggeredListSlideIn> createState() => _StaggeredListSlideInState();
}

class _StaggeredListSlideInState extends State<_StaggeredListSlideIn>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _slideAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _slideAnimation = Tween<double>(
      begin: 40.0,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _opacityAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

    final delay = Duration(milliseconds: math.min(widget.index * 40, 300));
    Future.delayed(delay, () {
      if (mounted) {
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _slideAnimation.value),
          child: Opacity(opacity: _opacityAnimation.value, child: child),
        );
      },
      child: widget.child,
    );
  }
}

/// Animated 3-bar equalizer visualizer widget for playing song tile
class _AnimatedEqualizerBars extends StatefulWidget {
  final bool isPlaying;
  final Color color;

  const _AnimatedEqualizerBars({required this.isPlaying, required this.color});

  @override
  State<_AnimatedEqualizerBars> createState() => _AnimatedEqualizerBarsState();
}

class _AnimatedEqualizerBarsState extends State<_AnimatedEqualizerBars>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    if (widget.isPlaying) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant _AnimatedEqualizerBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.isPlaying && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final val = _controller.value;
        return SizedBox(
          height: 14,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _bar(4 + (val * 8)),
              const SizedBox(width: 2),
              _bar(12 - (val * 7)),
              const SizedBox(width: 2),
              _bar(6 + (val * 7)),
            ],
          ),
        );
      },
    );
  }

  Widget _bar(double height) {
    return Container(
      width: 2.5,
      height: widget.isPlaying ? height : 3,
      decoration: BoxDecoration(
        color: widget.color,
        borderRadius: BorderRadius.circular(1.5),
      ),
    );
  }
}

class _HomeScreenMoveResult {
  final bool physicalMove;
  final bool isCopyMode;
  const _HomeScreenMoveResult({
    required this.physicalMove,
    required this.isCopyMode,
  });
}

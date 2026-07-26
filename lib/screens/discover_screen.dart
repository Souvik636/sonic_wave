import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../services/discover_service.dart';
import '../providers/player_provider.dart';
import '../widgets/song_tile.dart';
import '../widgets/shimmer_loading.dart';
import '../widgets/premium_interaction.dart';
import '../theme/app_colors.dart';
import '../widgets/app_toast.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final DiscoverService _discoverService = DiscoverService();

  List<Song> _audiusTracks = [];
  List<Song> _jamendoTracks = [];
  bool _isLoadingAudius = true;
  bool _isLoadingJamendo = true;
  String _activeCategory = 'Audius Trending';

  final List<String> _categories = [
    'Audius Trending',
    'Jamendo Popular',
    'Favorites',
  ];

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    await Future.wait([
      _loadAudius(),
      _loadJamendo(),
    ]);
  }

  Future<void> _loadAudius() async {
    setState(() => _isLoadingAudius = true);
    try {
      final tracks = await _discoverService.fetchAudiusTrending();
      if (mounted) {
        setState(() {
          _audiusTracks = tracks;
          _isLoadingAudius = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoadingAudius = false);
      }
    }
  }

  Future<void> _loadJamendo() async {
    setState(() => _isLoadingJamendo = true);
    try {
      final tracks = await _discoverService.fetchJamendoPopular();
      if (mounted) {
        setState(() {
          _jamendoTracks = tracks;
          _isLoadingJamendo = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoadingJamendo = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final playerProvider = Provider.of<PlayerProvider>(context);

    return SafeArea(
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // Header Hero Banner
          SliverToBoxAdapter(
            child: _buildHeroBanner(context, playerProvider),
          ),

          // Sub-Category Filter Chips Bar
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: SizedBox(
                height: 38,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  itemCount: _categories.length,
                  itemBuilder: (ctx, idx) {
                    final cat = _categories[idx];
                    final isSelected = _activeCategory == cat;
                    final primaryColor = Theme.of(context).colorScheme.primary;

                    return GestureDetector(
                      onTap: () => setState(() => _activeCategory = cat),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: const EdgeInsets.only(right: 8),
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
                                    color: primaryColor.withValues(alpha: 0.35),
                                    blurRadius: 10,
                                    spreadRadius: 1,
                                  ),
                                ]
                              : [],
                        ),
                        child: Text(
                          cat,
                          style: GoogleFonts.inter(
                            color: isSelected ? Colors.white : AppColors.textSecondary,
                            fontSize: 12,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),

          // Content List according to selected category
          if (_activeCategory == 'Favorites') ...[
            _buildFavoritesList(context, playerProvider),
          ] else if (_activeCategory == 'Jamendo Popular') ...[
            _buildTrackSliverList(
              context,
              songs: _jamendoTracks,
              isLoading: _isLoadingJamendo,
              onRefresh: _loadJamendo,
              emptyMessage: 'No popular Jamendo tracks found.',
              sourceTag: 'Jamendo',
            ),
          ] else ...[
            _buildTrackSliverList(
              context,
              songs: _audiusTracks,
              isLoading: _isLoadingAudius,
              onRefresh: _loadAudius,
              emptyMessage: 'No trending Audius tracks found.',
              sourceTag: 'Audius',
            ),
          ],

          const SliverToBoxAdapter(
            child: SizedBox(height: 140),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroBanner(BuildContext context, PlayerProvider playerProvider) {
    final primary = Theme.of(context).colorScheme.primary;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            primary.withValues(alpha: 0.28),
            Colors.purpleAccent.withValues(alpha: 0.15),
            AppColors.surfaceVariant.withValues(alpha: 0.6),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: primary.withValues(alpha: 0.4), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: primary.withValues(alpha: 0.18),
            blurRadius: 26,
            spreadRadius: 2,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: primary.withValues(alpha: 0.4), width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.explore_rounded, color: primary, size: 14),
                    const SizedBox(width: 6),
                    Text(
                      'EXPLORE INDIE & GLOBAL',
                      style: GoogleFonts.outfit(
                        color: primary,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),

              Icon(Icons.local_fire_department_rounded, color: Colors.amberAccent, size: 22),
            ],
          ),

          const SizedBox(height: 16),

          Text(
            'Discover New Sounds',
            style: GoogleFonts.outfit(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Stream trending independent tracks from Audius & Jamendo',
            style: GoogleFonts.inter(
              color: AppColors.textSecondary,
              fontSize: 12.5,
              height: 1.3,
            ),
          ),

          const SizedBox(height: 18),

          Row(
            children: [
              ElevatedButton.icon(
                onPressed: () {
                  final playlist = _activeCategory == 'Jamendo Popular' ? _jamendoTracks : _audiusTracks;
                  if (playlist.isNotEmpty) {
                    playerProvider.playPlaylist(playlist, startIndex: 0);
                    AppToast.show(context, 'Playing Discovery Trending', type: ToastType.info);
                  }
                },
                icon: const Icon(Icons.play_arrow_rounded, size: 20),
                label: const Text('Play Trending'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  elevation: 4,
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _loadAll,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Refresh'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.3), width: 1),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFavoritesList(BuildContext context, PlayerProvider playerProvider) {
    final favorites = playerProvider.favorites;

    if (favorites.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            children: [
              Icon(Icons.favorite_outline_rounded, size: 60, color: AppColors.textTertiary.withValues(alpha: 0.4)),
              const SizedBox(height: 16),
              Text(
                'No Favorites Saved Yet',
                style: GoogleFonts.outfit(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                'Tap the heart icon on any song to save it to your favorites list.',
                style: GoogleFonts.inter(color: AppColors.textTertiary, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final song = favorites[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: StaggeredReveal(
              index: index,
              child: SongTile(
                song: song,
                index: index,
                onTap: () {
                  playerProvider.playPlaylist(favorites, startIndex: index);
                },
              ),
            ),
          );
        },
        childCount: favorites.length,
      ),
    );
  }

  Widget _buildTrackSliverList(
    BuildContext context, {
    required List<Song> songs,
    required bool isLoading,
    required Future<void> Function() onRefresh,
    required String emptyMessage,
    required String sourceTag,
  }) {
    if (isLoading) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: ShimmerLoadingList(itemCount: 8),
        ),
      );
    }

    if (songs.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            children: [
              Icon(Icons.music_off_rounded, size: 54, color: AppColors.textTertiary.withValues(alpha: 0.4)),
              const SizedBox(height: 16),
              Text(
                emptyMessage,
                style: GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 14),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, color: Colors.white),
                onPressed: onRefresh,
              ),
            ],
          ),
        ),
      );
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final song = songs[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: StaggeredReveal(
              index: index,
              child: SongTile(
                song: song,
                index: index,
                sourceTag: sourceTag,
                onTap: () {
                  context.read<PlayerProvider>().playPlaylist(songs, startIndex: index);
                },
              ),
            ),
          );
        },
        childCount: songs.length,
      ),
    );
  }
}

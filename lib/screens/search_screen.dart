import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/player_provider.dart';
import '../providers/search_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_colors.dart';
import '../widgets/shimmer_loading.dart';
import '../widgets/song_tile.dart';
import 'package:google_fonts/google_fonts.dart';
import '../widgets/premium_interaction.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  late AnimationController _glowController;
  late Animation<double> _glowAnimation;
  bool _isFocused = false;
  String _selectedCategoryChip = '';

  @override
  void initState() {
    super.initState();
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _glowAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );

    _focusNode.addListener(() {
      setState(() => _isFocused = _focusNode.hasFocus);
      if (_focusNode.hasFocus) {
        _glowController.repeat(reverse: true);
      } else {
        _glowController.stop();
        _glowController.value = 0;
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    _glowController.dispose();
    super.dispose();
  }

  void _triggerSearch(String query) {
    if (query.trim().isEmpty) return;
    final settings = context.read<SettingsProvider>();
    final playerProvider = context.read<PlayerProvider>();
    _searchController.text = query;
    _focusNode.unfocus();
    context.read<SearchProvider>().search(
          searchQuery: query,
          offlineOnly: settings.offlineModeOnly,
          downloadedSongs: playerProvider.downloadedSongs,
        );
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final playerProvider = Provider.of<PlayerProvider>(context);
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Consumer<SearchProvider>(
      builder: (context, searchProvider, _) {
        return SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header Title & Subtitle
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const GradientHeadline('Search'),
                        const SizedBox(height: 2),
                        Text(
                          'Find songs, artists, playlists & genres',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textTertiary.withValues(alpha: 0.8),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    if (searchProvider.isLoading)
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: primaryColor,
                        ),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 10),

              // Search Bar Field with Animated Glowing Border
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: AnimatedBuilder(
                  animation: _glowAnimation,
                  builder: (context, child) {
                    return Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: _isFocused
                                ? primaryColor.withValues(alpha: 0.25 * _glowAnimation.value + 0.10)
                                : Colors.black.withValues(alpha: 0.2),
                            blurRadius: _isFocused ? 20 : 10,
                            spreadRadius: _isFocused ? 2 : 0,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: child,
                    );
                  },
                  child: TextField(
                    controller: _searchController,
                    focusNode: _focusNode,
                    onChanged: (val) {
                      setState(() => _selectedCategoryChip = '');
                      searchProvider.updateQuery(
                        val,
                        offlineOnly: settings.offlineModeOnly,
                        downloadedSongs: playerProvider.downloadedSongs,
                      );
                    },
                    onSubmitted: (val) => _triggerSearch(val),
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: AppColors.textPrimary,
                          fontSize: 15,
                        ),
                    decoration: InputDecoration(
                      hintText: 'Search music, artists, albums...',
                      hintStyle: TextStyle(
                        color: AppColors.textTertiary.withValues(alpha: 0.6),
                        fontSize: 14.5,
                      ),
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        color: _isFocused ? primaryColor : AppColors.textTertiary,
                        size: 22,
                      ),
                      suffixIcon: searchProvider.query.isNotEmpty
                          ? IconButton(
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _selectedCategoryChip = '');
                                searchProvider.clearSearch();
                              },
                              icon: const Icon(
                                Icons.close_rounded,
                                color: AppColors.textTertiary,
                                size: 20,
                              ),
                            )
                          : null,
                      filled: true,
                      fillColor: AppColors.surfaceVariant.withValues(alpha: 0.85),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide(
                          color: AppColors.glassBorder,
                          width: 0.8,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide(
                          color: AppColors.glassBorder,
                          width: 0.8,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide(
                          color: primaryColor,
                          width: 1.5,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Quick Category Shortcut Pills Bar
              _buildCategoryPills(searchProvider),

              const SizedBox(height: 8),

              // Content Area — animated switcher between results / loading / history / browse
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: _buildContent(searchProvider),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ════════════════════════════════════════════════════════════════════════
  // Quick Category Pills Filter Bar
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildCategoryPills(SearchProvider searchProvider) {
    final categories = ['Bollywood', 'Pop', 'Punjabi', 'Hip Hop', 'Lo-Fi', 'Rock', 'EDM', 'Romantic'];
    final primaryColor = Theme.of(context).colorScheme.primary;

    return SizedBox(
      height: 34,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: categories.length,
        itemBuilder: (context, index) {
          final cat = categories[index];
          final isSelected = _selectedCategoryChip == cat || searchProvider.query == cat;

          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: PremiumTap(
              onTap: () {
                AppHaptics.selection();
                setState(() => _selectedCategoryChip = cat);
                _triggerSearch(cat);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: isSelected
                      ? primaryColor
                      : AppColors.surfaceLight.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isSelected
                        ? primaryColor
                        : AppColors.glassBorder,
                    width: 0.8,
                  ),
                  boxShadow: isSelected
                      ? [
                          BoxShadow(
                            color: primaryColor.withValues(alpha: 0.4),
                            blurRadius: 10,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                child: Center(
                  child: Text(
                    cat,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                      color: isSelected ? Colors.white : AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════
  // Main Content Selector
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildContent(SearchProvider searchProvider) {
    final settings = context.read<SettingsProvider>();
    final playerProvider = context.read<PlayerProvider>();

    // 1. Live Autocomplete Suggestions
    if (searchProvider.suggestions.isNotEmpty &&
        searchProvider.query.isNotEmpty &&
        !searchProvider.hasResults) {
      return KeyedSubtree(
        key: const ValueKey('search_suggestions'),
        child: _buildSuggestions(searchProvider),
      );
    }

    // 2. Loading State (Shimmer list)
    if (searchProvider.isLoading) {
      return const Padding(
        key: ValueKey('search_loading'),
        padding: EdgeInsets.only(top: 16),
        child: ShimmerLoadingList(itemCount: 8),
      );
    }

    // 3. Error State
    if (searchProvider.error != null) {
      return KeyedSubtree(
        key: const ValueKey('search_error'),
        child: GlowEmptyState(
          icon: Icons.cloud_off_rounded,
          title: searchProvider.error!,
          action: ElevatedButton.icon(
            onPressed: () => searchProvider.search(
              searchQuery: searchProvider.query,
              offlineOnly: settings.offlineModeOnly,
              downloadedSongs: playerProvider.downloadedSongs,
            ),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Retry'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
          ),
        ),
      );
    }

    // 4. Search Results List
    if (searchProvider.hasResults) {
      return ListView.builder(
        key: const ValueKey('search_results'),
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.only(top: 8, bottom: 140),
        itemCount: searchProvider.results.length,
        itemBuilder: (context, index) {
          final song = searchProvider.results[index];
          return StaggeredReveal(
            index: index,
            child: SongTile(
              song: song,
              index: index,
              onTap: () {
                context.read<PlayerProvider>().playPlaylist(
                      searchProvider.results,
                      startIndex: index,
                    );
              },
            ),
          );
        },
      );
    }

    // 5. Default Home State: Recent Searches + Browse Categories Grid
    if (searchProvider.query.isEmpty) {
      return KeyedSubtree(
        key: const ValueKey('search_home_browse'),
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 140),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Recent / Previous Searches Section
              if (searchProvider.recentSearches.isNotEmpty)
                _buildRecentSearchesSection(searchProvider),

              // Browse Genre Categories Section
              _buildBrowseCategoriesGrid(),
            ],
          ),
        ),
      );
    }

    return const SizedBox.shrink(key: ValueKey('search_empty'));
  }

  // ════════════════════════════════════════════════════════════════════════
  // Live Suggestions List
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildSuggestions(SearchProvider searchProvider) {
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: searchProvider.suggestions.length,
      itemBuilder: (context, index) {
        final suggestion = searchProvider.suggestions[index];
        return StaggeredReveal(
          index: index,
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: ListTile(
              dense: true,
              leading: Icon(
                Icons.search_rounded,
                color: Theme.of(context).colorScheme.primary,
                size: 20,
              ),
              title: Text(
                suggestion,
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              trailing: Transform.rotate(
                angle: -0.785,
                child: const Icon(
                  Icons.arrow_upward_rounded,
                  color: AppColors.textTertiary,
                  size: 18,
                ),
              ),
              onTap: () => _triggerSearch(suggestion),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        );
      },
    );
  }

  // ════════════════════════════════════════════════════════════════════════
  // Recent Searches Section (Previous Searches History)
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildRecentSearchesSection(SearchProvider searchProvider) {
    final recentList = searchProvider.recentSearches;
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.history_rounded, size: 18, color: primaryColor),
                  const SizedBox(width: 6),
                  Text(
                    'Recent Searches',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
              TextButton(
                onPressed: () {
                  AppHaptics.medium();
                  searchProvider.clearRecentSearches();
                },
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(50, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'Clear All',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textTertiary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: recentList.map((item) {
              return PremiumTap(
                onTap: () => _triggerSearch(item),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceLight.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppColors.glassBorder,
                      width: 0.8,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.access_time_rounded,
                        size: 13,
                        color: AppColors.textTertiary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        item,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () {
                          AppHaptics.light();
                          searchProvider.removeFromRecentSearches(item);
                        },
                        child: const Padding(
                          padding: EdgeInsets.all(2.0),
                          child: Icon(
                            Icons.close_rounded,
                            size: 14,
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════════════
  // Browse Categories Grid with Fixed High Quality Images & Icons
  // ════════════════════════════════════════════════════════════════════════
  Widget _buildBrowseCategoriesGrid() {
    final settings = context.read<SettingsProvider>();
    final primaryColor = Theme.of(context).colorScheme.primary;

    // Curated list of genre categories with guaranteed working images & vibrant gradients
    final categories = [
      _CategoryItem(
        'Bollywood Hits',
        [const Color(0xFFFF6584), const Color(0xFFFF9A5C)],
        'https://images.unsplash.com/photo-1514525253161-7a46d19cd819?w=500&q=80',
        Icons.movie_filter_rounded,
      ),
      _CategoryItem(
        'Pop Hits',
        [settings.accentColor, settings.accentColorDark],
        'https://images.unsplash.com/photo-1511671782779-c97d3d27a1d4?w=500&q=80',
        Icons.music_note_rounded,
      ),
      _CategoryItem(
        'Punjabi Beats',
        [const Color(0xFFFF8008), const Color(0xFFFFC837)],
        'https://images.unsplash.com/photo-1516450360452-9312f5e86fc7?w=500&q=80',
        Icons.celebration_rounded,
      ),
      _CategoryItem(
        'Hip Hop & Rap',
        [AppColors.accent, const Color(0xFFFF9A5C)],
        'https://images.unsplash.com/photo-1508700115892-45ecd05ae2ad?w=500&q=80',
        Icons.headphones_rounded,
      ),
      _CategoryItem(
        'Lo-Fi Chill',
        [AppColors.secondary, const Color(0xFF009B7D)],
        'https://images.unsplash.com/photo-1518609878373-06d740f60d8b?w=500&q=80',
        Icons.nightlight_round,
      ),
      _CategoryItem(
        'Rock & Metal',
        [const Color(0xFFFF4D6A), const Color(0xFFFF1744)],
        'https://images.unsplash.com/photo-1498038432885-c6f3f1b912ee?w=500&q=80',
        Icons.electric_bolt_rounded,
      ),
      _CategoryItem(
        'EDM & Dance',
        [const Color(0xFF00B4D8), primaryColor],
        'https://images.unsplash.com/photo-1470225620780-dba8ba36b745?w=500&q=80',
        Icons.graphic_eq_rounded,
      ),
      _CategoryItem(
        'Romantic',
        [const Color(0xFFFF5252), const Color(0xFFFF79B0)],
        'https://images.unsplash.com/photo-1510915361894-db8b60106cb1?w=500&q=80',
        Icons.favorite_rounded,
      ),
      _CategoryItem(
        'Classical',
        [const Color(0xFF845EC2), const Color(0xFFB39DDB)],
        'https://images.unsplash.com/photo-1465847899084-d164df4dedc6?w=500&q=80',
        Icons.piano_rounded,
      ),
      _CategoryItem(
        'Workout',
        [const Color(0xFF11998E), const Color(0xFF38EF7D)],
        'https://images.unsplash.com/photo-1574680096145-d05b474e2155?w=500&q=80',
        Icons.fitness_center_rounded,
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.explore_rounded, size: 18, color: primaryColor),
              const SizedBox(width: 6),
              Text(
                'Browse Genres',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.75,
            ),
            itemCount: categories.length,
            itemBuilder: (context, index) {
              final cat = categories[index];
              return _CategoryCard(
                category: cat,
                onTap: () {
                  setState(() => _selectedCategoryChip = cat.name);
                  _triggerSearch(cat.name);
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CategoryItem {
  final String name;
  final List<Color> colors;
  final String imageUrl;
  final IconData icon;

  const _CategoryItem(this.name, this.colors, this.imageUrl, this.icon);
}

/// Premium Category Card Widget with Image + Fallback Gradient & Icon
class _CategoryCard extends StatelessWidget {
  final _CategoryItem category;
  final VoidCallback onTap;

  const _CategoryCard({
    required this.category,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return PremiumTap(
      onTap: onTap,
      pressedScale: 0.95,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: category.colors[0].withValues(alpha: 0.28),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Background Base Gradient
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: category.colors,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),

              // Network Image with Error Fallback
              CachedNetworkImage(
                imageUrl: category.imageUrl,
                fit: BoxFit.cover,
                fadeInDuration: const Duration(milliseconds: 250),
                errorWidget: (context, url, error) => const SizedBox.shrink(),
                placeholder: (context, url) => Container(
                  color: Colors.black12,
                ),
              ),

              // Dark Overlay Gradient for Readability
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.3),
                      Colors.black.withValues(alpha: 0.75),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),

              // Decorative Icon Watermark at Top-Right
              Positioned(
                top: -6,
                right: -6,
                child: Icon(
                  category.icon,
                  size: 54,
                  color: Colors.white.withValues(alpha: 0.18),
                ),
              ),

              // Category Label & Icon at Bottom-Left
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          category.icon,
                          size: 15,
                          color: Colors.white70,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            category.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              height: 1.1,
                              shadows: [
                                Shadow(
                                  color: Colors.black87,
                                  blurRadius: 6,
                                  offset: Offset(0, 1),
                                ),
                              ],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
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
      ),
    );
  }
}

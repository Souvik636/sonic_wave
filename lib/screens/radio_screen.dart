import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/song.dart';
import '../services/radio_service.dart';
import '../providers/player_provider.dart';
import '../widgets/song_tile.dart';
import '../widgets/shimmer_loading.dart';
import '../widgets/premium_interaction.dart';
import '../theme/app_colors.dart';

class RadioScreen extends StatefulWidget {
  const RadioScreen({super.key});

  @override
  State<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends State<RadioScreen> {
  final RadioService _radioService = RadioService();
  final TextEditingController _filterController = TextEditingController();

  List<Song> _allStations = [];
  List<Song> _filteredStations = [];
  List<Song> _globalResults = [];
  bool _isLoading = true;
  bool _isSearchingGlobal = false;
  String _filterText = '';
  Timer? _globalSearchDebounce;
  int _searchGeneration = 0;

  String _selectedCategoryChip = 'All';
  final List<String> _categoryChips = [
    'All',
    '🇮🇳 India',
    '🇬🇧 UK',
    '🇺🇸 USA',
    '🇪🇸 EDM',
    '☕ Lo-Fi',
    '🎷 Jazz',
    '🇫🇷 France',
    '🇰🇷 K-Pop',
  ];

  @override
  void initState() {
    super.initState();
    _loadStations();
    _filterController.addListener(() {
      setState(() {
        _filterText = _filterController.text.toLowerCase();
        _applyFilter();
      });
      _scheduleGlobalSearch();
    });
  }

  @override
  void dispose() {
    _globalSearchDebounce?.cancel();
    _filterController.dispose();
    super.dispose();
  }

  /// Debounced worldwide Radio-Browser search. Runs alongside the instant
  /// local filter so typing shows Indian matches immediately and global
  /// stations stream in ~600ms later.
  void _scheduleGlobalSearch() {
    _globalSearchDebounce?.cancel();
    final query = _filterController.text.trim();
    if (query.length < 2) {
      setState(() {
        _globalResults = [];
        _isSearchingGlobal = false;
      });
      return;
    }
    _globalSearchDebounce = Timer(const Duration(milliseconds: 600), () async {
      final generation = ++_searchGeneration;
      setState(() => _isSearchingGlobal = true);
      try {
        final results = await _radioService.searchStations(query);
        if (!mounted || generation != _searchGeneration) return;
        // Drop global hits already shown by the local list.
        final localIds = _filteredStations.map((s) => s.videoId).toSet();
        setState(() {
          _globalResults =
              results.where((s) => !localIds.contains(s.videoId)).toList();
          _isSearchingGlobal = false;
        });
      } catch (_) {
        if (mounted && generation == _searchGeneration) {
          setState(() => _isSearchingGlobal = false);
        }
      }
    });
  }

  Future<void> _loadStations() async {
    setState(() => _isLoading = true);
    try {
      final stations = await _radioService.fetchTopStations();
      if (mounted) {
        setState(() {
          _allStations = stations;
          _isLoading = false;
          _applyFilter();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _applyFilter() {
    List<Song> base = _allStations;

    if (_selectedCategoryChip != 'All') {
      final chipKey = _selectedCategoryChip.replaceAll(RegExp(r'[^\w\s]'), '').trim().toLowerCase();
      base = base.where((s) {
        final title = s.title.toLowerCase();
        final artist = s.artist.toLowerCase();
        return title.contains(chipKey) || artist.contains(chipKey);
      }).toList();
    }

    if (_filterText.isEmpty) {
      _filteredStations = List.from(base);
    } else {
      _filteredStations = base.where((station) {
        return station.title.toLowerCase().contains(_filterText) ||
            station.artist.toLowerCase().contains(_filterText);
      }).toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    final playerProvider = Provider.of<PlayerProvider>(context);

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: GradientHeadline('Live World Radio'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Text(
              'Curated Indian & International live broadcasts worldwide',
              style: GoogleFonts.outfit(
                color: AppColors.textTertiary,
                fontSize: 13,
              ),
            ),
          ),

          // Live Broadcasting Banner (if playing radio)
          _buildLiveRadioHeader(playerProvider),

          // Filter bar
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: TextField(
              controller: _filterController,
              style: Theme.of(context).textTheme.bodyLarge,
              decoration: InputDecoration(
                hintText: 'Search worldwide stations by name, genre, country...',
                hintStyle: TextStyle(
                  color: AppColors.textTertiary.withValues(alpha: 0.6),
                  fontSize: 12.5,
                ),
                prefixIcon: const Icon(Icons.search_rounded, color: AppColors.textTertiary),
                suffixIcon: _filterController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close_rounded, color: AppColors.textTertiary, size: 18),
                        onPressed: () => _filterController.clear(),
                      )
                    : null,
                filled: true,
                fillColor: AppColors.surfaceVariant.withValues(alpha: 0.5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(
                    color: Theme.of(context).colorScheme.primary,
                    width: 1.5,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),

          // Category Chips Row
          SizedBox(
            height: 38,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _categoryChips.length,
              itemBuilder: (ctx, idx) {
                final chip = _categoryChips[idx];
                final isSelected = _selectedCategoryChip == chip;
                final primaryColor = Theme.of(context).colorScheme.primary;

                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _selectedCategoryChip = chip;
                      _applyFilter();
                    });
                  },
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
                    ),
                    child: Text(
                      chip,
                      style: TextStyle(
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

          const SizedBox(height: 8),

          // Content
          Expanded(
            child: _buildContent(playerProvider),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveRadioHeader(PlayerProvider playerProvider) {
    final current = playerProvider.currentSong;
    if (current == null || !RadioService.isRadioId(current.id)) return const SizedBox.shrink();

    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            primary.withValues(alpha: 0.25),
            Colors.purpleAccent.withValues(alpha: 0.1),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: primary.withValues(alpha: 0.4), width: 1),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              color: Colors.redAccent,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: Colors.redAccent, blurRadius: 8, spreadRadius: 1),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('BROADCASTING LIVE', style: TextStyle(color: Colors.redAccent, fontSize: 9.5, fontWeight: FontWeight.w900, letterSpacing: 1)),
                Text(
                  current.title,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Icon(Icons.graphic_eq_rounded, color: primary, size: 22),
        ],
      ),
    );
  }

  Widget _buildContent(PlayerProvider playerProvider) {
    if (_isLoading) {
      return const ShimmerLoadingList(itemCount: 8);
    }

    if (_allStations.isEmpty) {
      return GlowEmptyState(
        icon: Icons.radio,
        title: 'Failed to load radio stations.',
        action: IconButton(
          icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
          onPressed: _loadStations,
        ),
      );
    }

    if (_filteredStations.isEmpty && _globalResults.isEmpty && !_isSearchingGlobal) {
      return const GlowEmptyState(
        icon: Icons.radio,
        title: 'No radio stations match your search.',
        subtitle: 'Try a different name, genre or language — searches worldwide.',
      );
    }

    // Combined list: local (Indian) matches first, then a "Worldwide" section
    // with global Radio-Browser results while a query is active.
    final bool showGlobal = _filterText.isNotEmpty &&
        (_globalResults.isNotEmpty || _isSearchingGlobal);
    final int localCount = _filteredStations.length;
    final int globalHeaderIndex = showGlobal ? localCount : -1;
    final int totalCount = localCount +
        (showGlobal ? 1 + _globalResults.length + (_isSearchingGlobal ? 1 : 0) : 0);

    return RefreshIndicator(
      onRefresh: _loadStations,
      color: Theme.of(context).colorScheme.primary,
      backgroundColor: AppColors.surfaceVariant,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 4, bottom: 140),
        itemCount: totalCount,
        itemBuilder: (context, index) {
          // Local stations
          if (index < localCount) {
            final station = _filteredStations[index];
            return StaggeredReveal(
              index: index,
              child: SongTile(
                song: station,
                index: index,
                onTap: () {
                  context.read<PlayerProvider>().playPlaylist([station], startIndex: 0);
                },
              ),
            );
          }
          // "Worldwide" section header
          if (index == globalHeaderIndex) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Row(
                children: [
                  Icon(Icons.public_rounded,
                      size: 16, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    'WORLDWIDE STATIONS',
                    style: GoogleFonts.outfit(
                      color: AppColors.textTertiary,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                    ),
                  ),
                  if (_isSearchingGlobal) ...[
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ],
              ),
            );
          }
          // Global results (or trailing spinner row while loading)
          final gIndex = index - localCount - 1;
          if (gIndex >= _globalResults.length) {
            return const SizedBox(height: 40);
          }
          final station = _globalResults[gIndex];
          return StaggeredReveal(
            index: gIndex,
            child: SongTile(
              song: station,
              index: index - 1,
              onTap: () {
                context.read<PlayerProvider>().playPlaylist([station], startIndex: 0);
              },
            ),
          );
        },
      ),
    );
  }
}

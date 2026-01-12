import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:http/http.dart' as http;
import '../constants.dart';

class LyricsFullScreen extends StatefulWidget {
  final List<SongModel> allSongs;
  final AudioPlayer audioPlayer;

  final ValueNotifier<int> currentIndexNotifier;
  final ValueNotifier<List<Map<String, dynamic>>> lyricsNotifier;

  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onPlayPause;
  final VoidCallback onShowAiModal;

  const LyricsFullScreen({
    super.key,
    required this.allSongs,
    required this.audioPlayer,
    required this.currentIndexNotifier,
    required this.lyricsNotifier,
    required this.onPrev,
    required this.onNext,
    required this.onPlayPause,
    required this.onShowAiModal,
  });

  @override
  State<LyricsFullScreen> createState() => _LyricsFullScreenState();
}

class _LyricsFullScreenState extends State<LyricsFullScreen> {
  final ItemScrollController _itemScrollController = ItemScrollController();
  int _highlightedLineIndex = -1;
  bool _isPlaying = false;

  // ✨ [상태 변수 3형제]
  bool _showTranslation = false; // 화면에 번역이 보이는지?
  bool _hasTranslation = false; // 번역 데이터를 가지고 있는지?
  bool _isTranslating = false; // 서버 통신 중인지? (로딩)

  @override
  void initState() {
    super.initState();
    _isPlaying = widget.audioPlayer.playing;

    // 1. 노래가 바뀌면 -> 번역 상태 초기화 (다시 '가사 번역' 버튼 뜨게 함)
    widget.currentIndexNotifier.addListener(_resetTranslationState);

    // 2. 가사 스크롤 싱크 로직
    widget.audioPlayer.positionStream.listen((p) {
      if (!mounted) return;
      var currentLyrics = widget.lyricsNotifier.value;
      if (currentLyrics.isEmpty) return;

      double currentSeconds = p.inMilliseconds / 1000.0;
      int foundIndex = -1;

      for (int i = 0; i < currentLyrics.length; i++) {
        if ((currentLyrics[i]['start'] as num).toDouble() <= currentSeconds) {
          foundIndex = i;
        } else {
          break;
        }
      }

      if (foundIndex != -1 && foundIndex != _highlightedLineIndex) {
        setState(() => _highlightedLineIndex = foundIndex);
        _scrollToIndex(foundIndex);
      }
    });

    widget.audioPlayer.playerStateStream.listen((state) {
      if (mounted) setState(() => _isPlaying = state.playing);
    });
  }

  @override
  void dispose() {
    widget.currentIndexNotifier.removeListener(_resetTranslationState);
    super.dispose();
  }

  // ✨ 노래 변경 시 상태 초기화
  void _resetTranslationState() {
    if (mounted) {
      setState(() {
        _showTranslation = false;
        _hasTranslation = false; // 새 노래는 번역 데이터 없음 -> '가사 번역' 버튼 뜸
        _isTranslating = false;
      });
    }
  }

  // 🖱️ [버튼 클릭 핸들러]
  void _handleTranslationButton() {
    // 1. 이미 번역 데이터가 있으면 -> 단순히 보이기/숨기기 토글
    if (_hasTranslation) {
      setState(() {
        _showTranslation = !_showTranslation;
      });
      return;
    }

    // 2. 번역 데이터가 없으면 -> 서버에 요청 (최초 1회)
    _fetchTranslation();
  }

  // 📡 [서버 통신] 번역 가져오기
  Future<void> _fetchTranslation() async {
    final currentLyrics = widget.lyricsNotifier.value;
    if (currentLyrics.isEmpty) return;

    // 혹시 데이터에 이미 번역이 있는지 확인 (재요청 방지)
    if (currentLyrics.first.containsKey('translated_text') &&
        currentLyrics.first['translated_text'].toString().isNotEmpty) {
      setState(() {
        _hasTranslation = true;
        _showTranslation = true;
      });
      return;
    }

    setState(() => _isTranslating = true); // 로딩 시작

    try {
      final url = Uri.parse("http://10.140.193.43:8000/translate");
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(
          currentLyrics
              .map(
                (e) => {
                  "start": e['start'],
                  "text": e['text'],
                  "translated_text": "",
                },
              )
              .toList(),
        ),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final newSegments = List<Map<String, dynamic>>.from(data['segments']);

        widget.lyricsNotifier.value = newSegments;

        // ✨ 성공! 이제 '가사 번역' 버튼은 사라지고 '번역 끄기'가 됨
        setState(() {
          _hasTranslation = true;
          _showTranslation = true;
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("번역 실패: ${response.statusCode}")),
        );
      }
    } catch (e) {
      print("번역 에러: $e");
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("서버 연결 실패")));
    } finally {
      setState(() => _isTranslating = false); // 로딩 끝
    }
  }

  void _scrollToIndex(int index) {
    if (_itemScrollController.isAttached) {
      _itemScrollController.scrollTo(
        index: index,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        alignment: 0.5,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: widget.currentIndexNotifier,
      builder: (context, currentIndex, _) {
        var song = widget.allSongs[currentIndex];

        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  margin: const EdgeInsets.only(right: 10),
                  color: kAppGrey,
                  child: QueryArtworkWidget(
                    id: song.id,
                    type: ArtworkType.AUDIO,
                    nullArtworkWidget: const Icon(Icons.music_note),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        song.artist ?? "Unknown",
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          body: Column(
            children: [
              // 🎵 가사 리스트
              Expanded(
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: kAppGrey,
                    border: Border.all(color: Colors.grey),
                  ),

                  child: ValueListenableBuilder<List<Map<String, dynamic>>>(
                    valueListenable: widget.lyricsNotifier,
                    builder: (context, lyrics, _) {
                      if (lyrics.isEmpty) {
                        return const Center(child: Text("가사가 없습니다."));
                      }
                      return ScrollablePositionedList.builder(
                        itemScrollController: _itemScrollController,
                        itemCount: lyrics.length,
                        itemBuilder: (context, index) {
                          bool isActive = index == _highlightedLineIndex;
                          String originalText = lyrics[index]['text'] ?? "";
                          String translatedText =
                              lyrics[index]['translated_text'] ?? "";

                          return Container(
                            padding: const EdgeInsets.symmetric(
                              vertical: 10,
                              horizontal: 10,
                            ),
                            alignment: Alignment.center,
                            child: Column(
                              children: [
                                // 원문
                                Text(
                                  originalText,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: isActive
                                        ? Colors.black
                                        : Colors.grey,
                                    fontWeight: isActive
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    fontSize: isActive ? 20 : 16,
                                  ),
                                ),
                                // 번역문 (조건부 표시)
                                if (_showTranslation &&
                                    translatedText.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4.0),
                                    child: Text(
                                      translatedText,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: isActive
                                            ? Colors.grey[800]
                                            : Colors.grey[500],
                                        fontWeight: FontWeight.normal,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ),

              // ⏯️ 재생 컨트롤러
              Container(
                padding: const EdgeInsets.only(bottom: 20, top: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, size: 40),
                      onPressed: widget.onPrev,
                    ),
                    const SizedBox(width: 20),
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: kAppBlack),
                      ),
                      child: IconButton(
                        icon: Icon(
                          _isPlaying ? Icons.pause : Icons.play_arrow,
                          size: 40,
                        ),
                        onPressed: widget.onPlayPause,
                      ),
                    ),
                    const SizedBox(width: 20),
                    IconButton(
                      icon: const Icon(Icons.arrow_forward, size: 40),
                      onPressed: widget.onNext,
                    ),
                  ],
                ),
              ),

              // 🔘 하단 버튼 영역
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    ElevatedButton(
                      onPressed: () {},
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kAppGrey,
                        minimumSize: const Size(100, 45),
                      ),
                      child: const Text("가사 넣기"),
                    ),

                    // ✨ [여기가 핵심!] 스마트 번역 버튼
                    ElevatedButton(
                      onPressed: _isTranslating
                          ? null
                          : _handleTranslationButton,
                      style: ElevatedButton.styleFrom(
                        // 번역이 켜져있을 때만 노란색 (활성 상태)
                        backgroundColor: (_showTranslation)
                            ? kAppYellow
                            : kAppGrey,
                        minimumSize: const Size(100, 45),
                      ),
                      child: _isTranslating
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: kAppBlack,
                              ),
                            )
                          // 👇 상태에 따른 텍스트 변화
                          : Row(
                              children: [
                                Icon(
                                  // 아이콘도 바뀝니다!
                                  !_hasTranslation
                                      ? Icons.translate
                                      : (_showTranslation
                                            ? Icons.visibility_off
                                            : Icons.visibility),
                                  size: 16,
                                  color: kAppBlack,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  !_hasTranslation
                                      ? "가사 번역" // 1. 번역 전 (서버 요청 필요)
                                      : (_showTranslation
                                            ? "번역 끄기" // 2. 번역 후 (화면 끄기)
                                            : "번역 켜기"), // 3. 번역 후 (화면 켜기)
                                  style: const TextStyle(color: kAppBlack),
                                ),
                              ],
                            ),
                    ),

                    ElevatedButton(
                      onPressed: widget.onShowAiModal,
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(100, 45),
                      ),
                      child: const Text("AI 생성"),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }
}

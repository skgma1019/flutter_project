import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart'; // 🏷️ 필수 import
import 'package:on_audio_query/on_audio_query.dart';

class AudioManager {
  // 싱글톤 패턴 (앱 전체에서 하나만 공유)
  static final AudioManager _instance = AudioManager._internal();
  factory AudioManager() => _instance;
  AudioManager._internal();

  final AudioPlayer player = AudioPlayer();
  List<SongModel> currentPlaylist = []; // 현재 재생 목록 저장

  Future<void> playSong(List<SongModel> songs, int index) async {
    currentPlaylist = songs; // 현재 리스트 업데이트

    try {
      // 1. 리스트 전체를 AudioSource로 변환 (MediaItem 태그 포함)
      final playlist = ConcatenatingAudioSource(
        children: songs.map((song) {
          return AudioSource.uri(
            Uri.parse(song.uri!), // 🎵 파일 경로 대신 URI 사용 (더 안정적)
            // 🏷️ [핵심] 잠금화면 & 알림창 정보 설정 (MediaItem)
            tag: MediaItem(
              id: song.id.toString(), // 고유 ID
              album: song.album ?? "Unknown Album",
              title: song.title, // 제목
              artist: song.artist ?? "Unknown Artist", // 가수
              // 🖼️ [수정됨] 앨범 아트 이미지 경로 설정
              // 안드로이드 내장 앨범 아트 경로 포맷입니다.
              artUri: Uri.parse(
                "content://media/external/audio/albumart/${song.albumId}",
              ),
            ),
          );
        }).toList(),
      );

      // 2. 플레이어에 리스트 설정 및 초기 위치 지정
      await player.setAudioSource(
        playlist,
        initialIndex: index, // 클릭한 노래부터 시작
        initialPosition: Duration.zero, // 0초부터 시작
      );

      // 3. 재생 시작
      player.play();
    } catch (e) {
      print("재생 실패: $e");
    }
  }
}

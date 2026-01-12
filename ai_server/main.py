from fastapi import FastAPI, UploadFile, File, Form, Body
from fastapi.responses import JSONResponse
# ⬇️ [추가] 데이터 모델링을 위한 라이브러리
from pydantic import BaseModel
from typing import List, Optional
import whisper
import shutil
import os
import re
import traceback
import subprocess
from deep_translator import GoogleTranslator

app = FastAPI()

# 모델 로드
print("⏳ 모델 로딩 중... (Small)")
model = whisper.load_model("small")
print("✅ 모델 로딩 완료!")

# ---------------------------------------------------------
# 📝 [추가] 데이터 모델 정의 (번역 요청 시 받을 데이터 구조)
# ---------------------------------------------------------
class LyricItem(BaseModel):
    start: float
    text: str
    translated_text: Optional[str] = ""

# ---------------------------------------------------------
# 🛠️ [기존 유지] FFmpeg 도구 찾기
# ---------------------------------------------------------
def get_ffmpeg_command():
    if shutil.which("ffmpeg"):
        return "ffmpeg"
    current_dir = os.path.dirname(os.path.abspath(__file__))
    local_ffmpeg = os.path.join(current_dir, "ffmpeg.exe")
    if os.path.exists(local_ffmpeg):
        return local_ffmpeg
    raise FileNotFoundError("FFmpeg를 찾을 수 없습니다.")

# ---------------------------------------------------------
# 🛠️ [기존 유지] WAV 변환 함수
# ---------------------------------------------------------
def convert_to_clean_wav(input_path):
    try:
        command_executable = get_ffmpeg_command()
        output_path = os.path.splitext(input_path)[0] + "_clean.wav"
        print(f"🔄 [변환 시작] {input_path} -> {output_path}")
        
        command = [
            command_executable, "-i", input_path, "-ar", "16000", "-ac", "1", 
            "-c:a", "pcm_s16le", "-vn", "-y", output_path
        ]
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return output_path
    except Exception as e:
        print(f"🚨 변환 실패: {e}")
        return input_path 

# ---------------------------------------------------------
# 🛠️ [기존 유지] 환각(Hallucination) 제거 함수
# ---------------------------------------------------------
def clean_hallucinations(segments):
    cleaned = []
    banned_words = ["lyrics", "lyrics.", "노래 가사", "mbc", "subtitles", "sous-titres", "시청해 주셔서 감사합니다"]
    
    for seg in segments:
        text = seg['text'].strip()
        if not text: continue
        if text.lower() in banned_words: continue
        if re.match(r'^[\W_]+$', text): continue
        cleaned.append(seg)
    return cleaned

# ---------------------------------------------------------
# 🛠️ [기존 유지] LRC 파싱 & 강제 싱크
# ---------------------------------------------------------
def parse_lrc_with_timestamp(lrc_content: str):
    segments = []
    pattern = re.compile(r'\[?(\d+):(\d+\.?\d*)\]?\s*(.*)')
    for line in lrc_content.splitlines():
        match = pattern.match(line.strip())
        if match:
            minutes, seconds, text = int(match.group(1)), float(match.group(2)), match.group(3).strip()
            if text:
                segments.append({"start": minutes * 60 + seconds, "text": text})
    return segments

def force_align_lyrics(whisper_result, user_text):
    ai_timestamps = [seg['start'] for seg in whisper_result['segments']]
    user_lines = [line.strip() for line in user_text.splitlines() if line.strip()]
    if not ai_timestamps or not user_lines: return []

    final_segments = []
    if not whisper_result['segments']: return [] 

    total_ai_duration = whisper_result['segments'][-1]['end'] - whisper_result['segments'][0]['start']
    start_offset = whisper_result['segments'][0]['start']
    
    for i, line in enumerate(user_lines):
        percent = i / len(user_lines)
        calculated_time = round(start_offset + (total_ai_duration * percent), 2)
        final_segments.append({"start": calculated_time, "text": line})
    return final_segments

# ---------------------------------------------------------
# 🌍 [수정] 번역 실행 함수 (독립적으로 사용 가능하게 변경)
# ---------------------------------------------------------
def perform_translation(segments, target_lang='ko'):
    print("🌍 [번역 실행] Google Translate...")
    translator = GoogleTranslator(source='auto', target=target_lang)
    
    for seg in segments:
        try:
            # 딕셔너리인지 객체인지 확인하여 처리
            original = seg['text'] if isinstance(seg, dict) else seg.text
            
            translated = translator.translate(original)
            
            if isinstance(seg, dict):
                seg['translated_text'] = translated
            else:
                seg.translated_text = translated
        except Exception as e:
            print(f"⚠️ 번역 실패 (부분): {e}")
            if isinstance(seg, dict):
                seg['translated_text'] = ""
            else:
                seg.translated_text = ""
            
    print("✅ [번역 완료]")
    return segments

# =========================================================
# 🚀 API 1: 오디오 분석 (번역 기능 제거됨)
# =========================================================
@app.post("/analyze")
async def analyze_audio(
    file: UploadFile = File(...), 
    language: str = Form("auto"), 
    lyrics_text: str = Form(None)
):
    temp_filename = f"temp_{file.filename}"
    clean_audio_path = None
    actual_language = None if language == "auto" else language

    print(f"\n🚀 [분석 요청] {file.filename} / 언어: {actual_language if actual_language else '자동'}")

    try:
        # 1. 원본 저장 및 변환
        with open(temp_filename, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
        clean_audio_path = convert_to_clean_wav(temp_filename)

        final_result = []

        # A. 사용자 가사 있음
        if lyrics_text:
            print(f"📝 사용자 가사 수신됨")
            parsed = parse_lrc_with_timestamp(lyrics_text)
            if len(parsed) > 0:
                print("✨ 시간 정보 포함됨 -> 바로 적용")
                final_result = parsed
            else:
                print("💡 텍스트만 있음 -> AI로 시간 추출")
                raw_result = model.transcribe(clean_audio_path, language=actual_language, fp16=False)
                final_result = force_align_lyrics(raw_result, lyrics_text)
        
        # B. 가사 없음 (AI 받아쓰기)
        else:
            print(f"🤖 가사 없음 -> AI 받아쓰기 모드")
            result = model.transcribe(
                clean_audio_path, 
                language=actual_language,
                initial_prompt="Hello, this is a song.", 
                fp16=False,
                condition_on_previous_text=False, 
                no_speech_threshold=0.6, 
                logprob_threshold=-1.0 
            )
            final_result = clean_hallucinations(result['segments'])

        # ⚠️ 중요: 여기서는 번역을 수행하지 않고 결과만 리턴합니다!
        
        # 파일 정리
        if os.path.exists(temp_filename): os.remove(temp_filename)
        if clean_audio_path != temp_filename and os.path.exists(clean_audio_path): 
            os.remove(clean_audio_path)
            
        return JSONResponse(content={"segments": final_result})

    except Exception as e:
        print(f"\n💥 에러 발생: {traceback.format_exc()}")
        if os.path.exists(temp_filename): os.remove(temp_filename)
        if clean_audio_path and clean_audio_path != temp_filename and os.path.exists(clean_audio_path): 
            os.remove(clean_audio_path)
        return JSONResponse(content={"error": str(e)}, status_code=500)

# =========================================================
# 🚀 API 2: 번역 전용 (버튼 누르면 호출됨) [신규 추가]
# =========================================================
@app.post("/translate")
async def translate_lyrics(lyrics: List[LyricItem]):
    print(f"\n🌍 [번역 요청] 총 {len(lyrics)}줄 번역 시작")
    
    try:
        # Pydantic 모델 리스트를 딕셔너리 리스트로 변환
        dict_lyrics = [item.dict() for item in lyrics]
        
        # 번역 수행
        translated_result = perform_translation(dict_lyrics)
        
        return JSONResponse(content={"segments": translated_result})
        
    except Exception as e:
        print(f"💥 번역 에러: {traceback.format_exc()}")
        return JSONResponse(content={"error": str(e)}, status_code=500)
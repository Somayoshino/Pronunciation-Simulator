import streamlit as st
import azure.cognitiveservices.speech as speechsdk
import tempfile
import os

# ==========================================
# ⚙️ Azure API の設定（ご自身のキーに変更してください）
# ==========================================
SPEECH_KEY = "YOUR_KEY"
SPEECH_REGION = "japaneast"

# ページ設定
st.set_page_config(page_title="発音判定アプリ", page_icon="🎤", layout="centered")

def get_tts_audio(text, accent):
    """Azure Text-to-Speechでお手本音声を生成する関数"""
    speech_config = speechsdk.SpeechConfig(subscription=SPEECH_KEY, region=SPEECH_REGION)
    
    # アクセントに応じたAIボイスを設定
    if accent == "US":
        speech_config.speech_synthesis_voice_name = "en-US-JennyNeural"
    else:
        speech_config.speech_synthesis_voice_name = "en-GB-SoniaNeural"
        
    # 音声をファイルに保存せずデータとして取得
    synthesizer = speechsdk.SpeechSynthesizer(speech_config=speech_config, audio_config=None)
    result = synthesizer.speak_text_async(text).get()
    
    if result.reason == speechsdk.ResultReason.SynthesizingAudioCompleted:
        return result.audio_data
    else:
        return None

def evaluate_pronunciation(audio_path, text, accent):
    """Azure Pronunciation Assessmentで発音を評価する関数"""
    speech_config = speechsdk.SpeechConfig(subscription=SPEECH_KEY, region=SPEECH_REGION)
    audio_config = speechsdk.audio.AudioConfig(filename=audio_path)
    
    lang = "en-US" if accent == "US" else "en-GB"
    
    # 評価設定（100点満点、音素レベルまで評価、ミス（読み飛ばし等）も検出）
    pronunciation_config = speechsdk.PronunciationAssessmentConfig(
        reference_text=text,
        grading_system=speechsdk.PronunciationAssessmentGradingSystem.HundredMark,
        granularity=speechsdk.PronunciationAssessmentGranularity.Phoneme,
        enable_miscue=True
    )
    
    speech_recognizer = speechsdk.SpeechRecognizer(speech_config=speech_config, language=lang, audio_config=audio_config)
    pronunciation_config.apply_to(speech_recognizer)
    
    # 音声認識と評価の実行
    result = speech_recognizer.recognize_once_async().get()
    
    if result.reason == speechsdk.ResultReason.RecognizedSpeech:
        # 評価結果の抽出
        pronunciation_result = speechsdk.PronunciationAssessmentResult(result)
        return pronunciation_result
    else:
        return None

# ==========================================
# 🎨 UI コンポーネント
# ==========================================
st.title("🎤 ネイティブ発音判定アプリ 🇺🇸🇬🇧")
st.write("テキストを入力して、マイクに向かって発音してください。")

st.markdown("### 1. テキストとアクセントの設定")
text_input = st.text_area("練習したい単語や文章を入力してください", "The quick brown fox jumps over the lazy dog.")
accent_choice = st.radio("アクセントを選択", ["アメリカ英語 (US)", "イギリス英語 (UK)"], horizontal=True)
accent_code = "US" if "US" in accent_choice else "UK"

st.markdown("### 2. 発音の録音")
audio_value = st.audio_input("マイクボタンを押して発音してください")

if audio_value and text_input:
    # 録音データを一時ファイルとして保存
    with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as tmp_file:
        tmp_file.write(audio_value.getvalue())
        tmp_filepath = tmp_file.name

    st.success("録音が完了しました！解析中...")
    
    with st.spinner("AIが発音を評価・生成しています..."):
        # 1. お手本音声の取得
        tts_audio_data = get_tts_audio(text_input, accent_code)
        
        # 2. 発音評価の実行
        assessment_result = evaluate_pronunciation(tmp_filepath, text_input, accent_code)
    
    # 一時ファイルの削除
    os.remove(tmp_filepath)

    st.markdown("---")
    st.header("📊 判定結果")
    
    if assessment_result:
        # スコアの表示
        col1, col2, col3, col4 = st.columns(4)
        col1.metric("総合スコア", f"{int(assessment_result.pronunciation_score)}")
        col2.metric("正確性", f"{int(assessment_result.accuracy_score)}")
        col3.metric("流暢さ", f"{int(assessment_result.fluency_score)}")
        col4.metric("完全性", f"{int(assessment_result.completeness_score)}")

        # お手本音声の表示
        st.subheader("🎧 お手本音声")
        if tts_audio_data:
            st.audio(tts_audio_data, format="audio/wav")
        else:
            st.error("お手本音声の生成に失敗しました。")
        
        # 詳細フィードバック（単語ごとの色分け）
        st.subheader("📝 詳細フィードバック")
        st.write("🟢 素晴らしい / 🟠 もう少し / 🔴 要改善（または発音抜け）")
        
        colored_text = ""
        for word in assessment_result.words:
            word_text = word.word
            score = word.accuracy_score
            error_type = word.error_type

            # Omission（読み飛ばし）またはスコアが低い場合は赤
            if error_type == "Omission" or score < 60:
                color = "#ff4b4b"
            elif score < 80:
                color = "#ffa500"
            else:
                color = "#00cc66"
                
            colored_text += f"<span style='color:{color}; font-weight:bold; margin-right:5px;' title='Score: {score}'>{word_text}</span>"
            
        st.markdown(f"<div style='font-size: 24px; background-color: #f0f2f6; padding: 20px; border-radius: 10px; line-height: 1.5;'>{colored_text}</div>", unsafe_allow_html=True)
        st.caption("※単語にマウスカーソルを合わせると、その単語の正確性スコアが表示されます。")

    else:
        st.error("音声を正しく認識できませんでした。もう少し大きな声で、はっきりと発音してみてください。")
# import streamlit as st
# import random
# import time

# # ページ設定
# st.set_page_config(page_title="発音判定アプリ", page_icon="🎤", layout="centered")

# st.title("🎤 ネイティブ発音判定アプリ 🇺🇸🇬🇧")
# st.write("テキストを入力して、マイクに向かって発音してください。")

# # 1. 設定エリア
# st.markdown("### 1. テキストとアクセントの設定")
# text_input = st.text_area("練習したい単語や文章を入力してください", "The quick brown fox jumps over the lazy dog.")
# accent = st.radio("アクセントを選択", ["アメリカ英語 (US)", "イギリス英語 (UK)"], horizontal=True)

# # 2. 録音エリア
# st.markdown("### 2. 発音の録音")
# # ブラウザのマイク機能を使って音声を録音
# audio_value = st.audio_input("マイクボタンを押して発音してください")

# # 録音データとテキストが両方揃った場合の処理
# if audio_value and text_input:
#     st.success("録音が完了しました！解析中...")
    
#     # --- ここから本来はAzure Speech APIを呼び出します ---
#     # 今回はプロトタイプの動きを確認するため、ダミーのスコアと処理時間を設定しています
#     with st.spinner("AIが発音を評価しています..."):
#         time.sleep(2) # API通信のラグを演出
        
#         # ランダムなダミースコアを生成
#         pronunciation_score = random.randint(70, 98)
#         accuracy_score = pronunciation_score + random.randint(-5, 2)
#         fluency_score = pronunciation_score + random.randint(-5, 5)
        
#     # 3. 結果表示
#     st.markdown("---")
#     st.header("📊 判定結果")
    
#     # スコアの表示
#     col1, col2, col3 = st.columns(3)
#     col1.metric("総合スコア", f"{pronunciation_score} / 100")
#     col2.metric("正確性", f"{accuracy_score} / 100")
#     col3.metric("流暢さ", f"{fluency_score} / 100")

#     # お手本音声のモック
#     st.subheader("🎧 お手本音声の確認")
#     st.info("※実装時はここに、Azure Text-to-Speechで生成したネイティブの音声プレーヤーが表示されます。")
    
#     # フィードバックのモック（単語ごとの色分け）
#     st.subheader("📝 詳細フィードバック")
#     st.write("🟢 完璧 / 🟠 改善の余地あり / 🔴 発音ミス・抜け")
    
#     # 入力されたテキストを単語に分割し、ランダムに色付けしてUIのイメージを掴む
#     words = text_input.split()
#     colored_text = ""
#     for word in words:
#         rand = random.random()
#         if rand > 0.9: # 10%の確率で赤
#             colored_text += f"<span style='color:#ff4b4b; font-weight:bold;'>{word}</span> "
#         elif rand > 0.7: # 20%の確率でオレンジ
#             colored_text += f"<span style='color:#ffa500; font-weight:bold;'>{word}</span> "
#         else: # 70%の確率で緑
#             colored_text += f"<span style='color:#00cc66; font-weight:bold;'>{word}</span> "
            
#     # HTMLとしてレンダリング
#     st.markdown(f"<div style='font-size: 24px; background-color: #f0f2f6; padding: 20px; border-radius: 10px;'>{colored_text}</div>", unsafe_allow_html=True)

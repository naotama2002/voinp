---
id: slack
name: Slack 向けに短く
name.en: For Slack
order: 30
lengthRatioMin: 0.4
lengthRatioMax: 1.2
requireSameScript: true
allowMarkdown: true
enforceNumbers: true
enforceQuestionShape: true
temperature: 0.2
---
チャットに投稿する前提で整形してください。

- 冗長な前置き（「お疲れさまです」「ちょっと相談なんですが」など）は削ってよい
- 話し言葉の重複や言い直しは削る
- 箇条書きにしたほうが読みやすい内容であれば箇条書きにしてよい
- ただし事実・数値・固有名詞・依頼内容は必ず残すこと
- 絶対に内容を要約して情報を落とさないこと。短くするのは表現であって中身ではない

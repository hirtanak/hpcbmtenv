# hpcbmtenv

Azure上でHPCベンチマークを作成するBashスクリプトです。
スクリプトは、VMベースで作成されVMSSやAzure CycleCloudは利用しません。

## コマンドについて
実行するには1,2,3個の引数が必要です。
create,delete,start,stop,stop-all,stopvm #,stopvm #1 #2,startvm #1,list,remount,pingpong,addlogin,updatensg,privatenw,publicnw の引数を一つ指定する必要があります。

## その他のコマンド"  1>&2
 - stop: すべてのコンピュートノードを停止します。
 - stop-all: すべてのコンピュートノード＋PBSノード・ログインノードもすべて停止します。
 - stopvm <vm#>: コンピュートノードVM#のみを停止します。
 - stopvms <start vm#> <end vm#>: コンピュートノードVM# xからVM# yまで停止します。
 - startvm <vm#>: コンピュートノードVM#を起動します。
 - list: VMの状況・およびマウンド状態を表示します。"  1>&2
 - listip: IPアドレスアサインの状態を表示します。"  1>&2
 - pingpong: すべてのノード間でpingpongを取得します。ローカルファイル result に保存します。
 - remount: デフォルトで設定されているディレクトリの再マウントを実施します。
 - publicnw コマンド: コンピュートノード、PBSノードからグローバルIPアドレスを再度追加します。
 - delete: すべてのコンピュートノードを削除します。
 - delete-all: すべてのコンピュートノード、PBSノード、ログインノードを削除します。
 - deletevm <vm#>: 特定のコンピュートノード#のみを削除します。(PBSの設定削除などは未実装)
 - checkfiles: ローカルで利用するスクリプトを生成します。
 - ssh: 各VMにアクセスできます。 例：$CMDNAME ssh 1: コンピュートノード#1にSSHアクセスします。

## 一般的な利用方法
0. updatensg コマンド: スクリプト実行ノードのグローバルIPを利用してセキュリティグループを設定します。
1. create コマンド: コンピュートノードを作成します。
2. addlogin コマンド: login, PBSノードを作成します。
3. 任意：privatenw コマンド: コンピュートノード、PBSノードからグローバルIPアドレスを除きます


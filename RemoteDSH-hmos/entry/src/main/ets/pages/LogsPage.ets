// 日志页（NavDestination）：内存环形日志（AppStorage logTail 驱动刷新）
@Component
export struct LogsPage {
  @StorageProp('logTail') logTail: string = ''

  build() {
    NavDestination() {
      Stack() {
        Scroll() {
          Text(this.logTail === '' ? '（暂无日志）' : this.logTail)
            .fontSize(11)
            .fontFamily('monospace')
            .copyOption(CopyOptions.InApp)
            .width('100%')
            .padding(12)
        }
        .scrollBar(BarState.Auto)
        .align(Alignment.Top)
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .alignContent(Alignment.Top)
    }
    .title('日志')
  }
}

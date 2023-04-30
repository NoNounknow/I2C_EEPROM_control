module iic_control
#(
    parameter   SYS_CLOCK = 50_000_000             ,//系统时钟
    parameter   SCL_CLOCK = 4_00_000               //scl时钟（阅读芯片手册获取）    
)
(
    input                       sys_clk            ,
    input                       Rst_n              ,
//地址     
    input               [2:0]   Device_addr        ,//器件地址
    input               [15:0]  Word_addr          ,//寄存器地址
    input                       wr_en              ,            
    input                       rd_en              ,
    input               [1:0]   Wd_addr_long       ,//寄存器地址字节长度
    input               [7:0]   wr_data            ,//写入数据
    input               [5:0]   wr_data_long       ,//写入数据字长
    input               [5:0]   rd_data_long       ,//读出数据字长

    output   wire               wr_data_done       ,
    output    reg               r_rd_data_done     ,

    output    reg               iic_busy_done      ,//读写完成的标志位
    output    reg               iic_scl            ,//scl
    output    reg       [7:0]   rd_data_out        ,//读取到的数据输出   
    inout                       iic_sda            

);
    localparam  SCL_cnt_max = SYS_CLOCK / SCL_CLOCK;//时钟计数器最大值
//状态机状态定义
    localparam
        IDLE        = 9'b000_000_001,//空闲状态
        WR_START    = 9'b000_000_010,//写开始
        WR_CTRL     = 9'b000_000_100,//写控制
        WR_WADDR    = 9'b000_001_000,//写入存储器地址
        WR_DATA     = 9'b000_010_000,//写入数据状态
        RD_START    = 9'b000_100_000,//读操作开始
        RD_CTRL     = 9'b001_000_000,//读操作控制
        RD_DATA     = 9'b010_000_000,//读数据状态
        STOP        = 9'b100_000_000;//停止
//状态机
            reg         [8:0]   state              ;
            reg                 sda_reg            ;//sda输出的寄存
            reg                 wr_flag            ;//写入开始的标志，和wr_en有关
            reg                 rd_flag            ;//读出开始的标志，和rd_en有关  
            reg         [7:0]   wr_data_cnt        ;//读写数据计数，位宽为1字节 
            reg         [7:0]   rd_data_cnt        ;//读写数据计数，位宽为1字节
            reg         [1:0]   word_addr_cnt      ;//寄存器地址长度计数器，此处只考虑1字节和2字节的情况  
//sda
            reg         [7:0]   iic_sda_out        ;//sda输出
            reg         [7:0]   iic_sda_in         ;//sda输入
            reg                 sda_en             ;//三态门使能信号

//scl时钟和iic的使用状态
            reg         [15:0]  scl_cnt            ; 
            reg                 iic_busy           ;
            reg                 scl_high           ;
            reg                 scl_low            ;
            reg         [7:0]   halfbit_cnt        ;//半字节计数器（上升下降计数器）
            reg                 ack                ;//应答信号    
            reg                 data_busy          ;//传输进行信号
//读写控制字（器件地址+读写位）
           wire         [7:0]   wr_control_sign    ;
           wire         [7:0]   rd_control_sign    ;
//读出写入完成
    //define
           wire                 rd_data_done        ; 
    assign  wr_data_done =  ( (state == WR_WADDR)
                            &&(word_addr_cnt == Wd_addr_long)
                            &&(wr_flag && scl_low)
                            &&(ack == 1'b1))
                        ||  ( (state == WR_DATA)
                            &&(scl_low)
                            &&(word_addr_cnt != Wd_addr_long));
    assign  rd_data_done =  (state == RD_DATA)
                            &&(halfbit_cnt == 8'd15)
                            &&(scl_low);

//r_rd_data_done
    always@(posedge sys_clk or negedge Rst_n)
        if(!Rst_n)
            r_rd_data_done <= 1'b0;
        else if(rd_data_done)
            r_rd_data_done <= 1'b1;
        else
            r_rd_data_done <= 1'b0;
//读入数据输出信号
    always@(posedge sys_clk or negedge Rst_n)
        if(!Rst_n)
            rd_data_out <= 8'b0;
        else if(rd_data_done)
            rd_data_out <= iic_sda_in;
        else
            rd_data_out <= rd_data_out;
//三态门sda
    assign iic_sda = (sda_en)? sda_reg:1'bz;
//sda_en的定义
 //对于三态门，希望其在写入数据的状态下能够发送信号，而在读取数据的时候接收信号
 //在写入地址前我们需要发送起始位，而读取地址前也需要发送起始位，所以他们需要全程使用三态门
 //对于停止状态下我们需要发送停止信号，所以也需要保持高电平
    always@(*)
        begin
            case(state)
                IDLE:
                    sda_en <= 1'b0;

                WR_START,
                STOP,
                RD_START:
                    sda_en <= 1'b1;

                RD_CTRL ,
                WR_CTRL ,
                WR_WADDR,
                WR_DATA :
                    if(halfbit_cnt < 8'd16)
                        sda_en <= 1'b1;
                    else
                        sda_en <= 1'b0;
                RD_DATA :
                    if(halfbit_cnt < 8'd16)
                        sda_en <= 1'b0;
                    else
                        sda_en <= 1'b1;
            default:    
                        sda_en <= 1'b0;
            endcase
        end
//读写控制字
    assign wr_control_sign = {4'b1010,Device_addr,1'b0};
    assign rd_control_sign = {4'b1010,Device_addr,1'b1};
//定义iic工作状态
    always@(posedge sys_clk or negedge Rst_n)
        begin
            if(!Rst_n)
                iic_busy <= 1'b0;
            else if(wr_en | rd_en)
                iic_busy <= 1'b1;
            else if(iic_busy_done)
                iic_busy <= 1'b0;
            else
                iic_busy <= iic_busy;
        end

//仅在iic工作状态产生时钟(计数器)
    always@(posedge sys_clk or negedge Rst_n)
        begin
            if(!Rst_n)
                scl_cnt <= 16'b0;
            else if (iic_busy)
                begin
                    if(scl_cnt == SCL_cnt_max - 1'b1)
                        scl_cnt <= 16'b0;
                    else
                        scl_cnt <= scl_cnt + 1'b1; 
                end
            else
                scl_cnt <= 16'b0;
        end
//iic时钟
    always@(posedge sys_clk or negedge Rst_n)
        begin
            if(!Rst_n)
                iic_scl <= 1'b1   ;
            else if(scl_cnt == SCL_cnt_max >> 1)//scl == 最大值的一半
                iic_scl <= 1'b0;
            else if(scl_cnt == 16'd0)           // 0-1/2 = 1 || 1/2-1 = 0
                iic_scl <= 1'b1;
            else
                iic_scl <= iic_scl;
        end
//由于数据只能在iic低电平的时候发生改变，记录iic的低电平情况
    // 0-1/2 = 1 || 1/2-1 = 0
    always@(posedge sys_clk or negedge Rst_n)
        begin
            if(!Rst_n)
                scl_high <= 1'b0;
            else if(scl_cnt == (SCL_cnt_max >> 2) )
                scl_high <= 1'b1;
            else
                scl_high <= 1'b0;
        end
    always@(posedge sys_clk or negedge Rst_n)
        begin
            if(!Rst_n)
                scl_low <= 1'b0;
            else if(scl_cnt == ((SCL_cnt_max >> 2) + (SCL_cnt_max >> 1)))
                scl_low <= 1'b1;
            else
                scl_low <= 1'b0;
        end
//scl时钟主导的计数器（高低电平计数器）
    //每当scl处于高，低电平的时候，halfbit_cnt都会增加
    always@(posedge sys_clk or negedge Rst_n)
        begin
            if(!Rst_n)
                halfbit_cnt <= 8'b0;
            else if(    (state == WR_CTRL )
                    |   (state == WR_WADDR)
                    |   (state == WR_DATA )
                    |   (state == RD_CTRL )
                    |   (state == RD_DATA )
                    )
                begin
                    if(scl_low | scl_high)
                        begin
                            if(halfbit_cnt == 8'd17)
                                halfbit_cnt <= 8'b0;
                            else
                                halfbit_cnt <= halfbit_cnt + 1'b1; 
                        end
                    else
                        halfbit_cnt <= halfbit_cnt;
                end
            else
                halfbit_cnt <= 8'd0;      
        end
//应答信号检测
    //应答信号：写入一个字节以后，从机将sda拉低示意写入完成
    always@(posedge sys_clk or negedge Rst_n)
        begin
            if(!Rst_n)
                ack <= 1'b0;
            else if((halfbit_cnt == 8'd16)&&(scl_high)&&(iic_sda == 1'b0))
                ack <= 1'b1;
            else if((halfbit_cnt == 8'd17)&&(scl_low))
                ack <= 1'b0;
            else
                ack <= ack;
        end
//sda读写控制
 //sda线上的数据仅在scl高电平的时候取用，在低电平的时候发生改变
    //所以在写入信号的时候在低电平改变写入的数据
    //读取信号的时候在高电平的时候改变读出的数据
    //输出串行数据任务（写）
 //输出仅在写入的适合使用，此时写入8bits数据以后等待应答
    task    send_data_8bits;
        if((scl_high)&&(halfbit_cnt == 8'd16))
            data_busy <= 1'b1;
        else if(halfbit_cnt < 8'd17)
            begin
               sda_reg <= iic_sda_out[7];
               if(scl_low)
                    iic_sda_out <= {iic_sda_out[6:0],1'b0};
                else
                    iic_sda_out <= iic_sda_out;
            end
        else
            data_busy <= data_busy;
    endtask
 //输入串行数据任务（读）
    task    receive_data_8bits;
        if((scl_low)&&(halfbit_cnt == 8'd15))
            begin
                data_busy    <= 1'b1;
            end
        else if(halfbit_cnt < 8'd15)
            begin
                if(scl_high)
                    iic_sda_in <= {iic_sda_in[6:0],iic_sda};
                else
                    iic_sda_in <= iic_sda_in;
            end
        else
            data_busy <= data_busy;
    endtask

//状态机
 /*  IDLE     
    WR_START 向写入信号中装入器件地址和读写控制位等 使task可用
    WR_CTRL  检查data_busy，传输状态则启动写任务 
            接收应答信号                    
            若没有接收到应答信号，则返回空闲状态。
            应该写入寄存器地址
            也需要考虑器件地址是两字节的情况
    WR_WADDR 1字节情况：此状态下提前写入准备写入的数据在寄存器中
             2字节情况：再跳转一次该状态完成剩下的寄存器地址的写入
    WR_DATA  1字节写入：下一个状态跳转到停止位，拉高任务电平，sda拉高
    RD_START 
    RD_CTRL  
    RD_DATA  
    STOP    
*/
    always@(posedge sys_clk or negedge Rst_n)
        begin
            if(!Rst_n) 
                begin
                    state         <= IDLE       ;
                    sda_reg       <= 1'b1       ;
                    wr_flag       <= 1'b0       ;
                    rd_flag       <= 1'b0       ;   
                    iic_busy_done <= 1'b0       ;
                    wr_data_cnt   <= 8'd1       ;
                    rd_data_cnt   <= 8'd1       ;    
                    word_addr_cnt <= 2'd1       ;                   
                end
            else 
                begin
                    case (state)
                        IDLE:
                            begin
                                sda_reg       <= 1'b1;
                                wr_flag       <= 1'b0;
                                rd_flag       <= 1'b0;
                                iic_busy_done <= 1'b0;
                                wr_data_cnt   <= 8'd1;
                                rd_data_cnt   <= 8'd1;
                                word_addr_cnt <= 2'd1;
                                if (wr_en) 
                                    begin
                                        state   <= WR_START;
                                        wr_flag <= 1'b1;
                                    end
                                else if(rd_en)
                                    begin
                                        state   <= WR_START;
                                        rd_flag <= 1'b1;
                                    end
                                else
                                    state <= IDLE;
                            end 
                        WR_START:
                            begin
                                if(scl_low)
                                    begin
                                        state       <= WR_CTRL        ;
                                        iic_sda_out <= wr_control_sign;
                                        data_busy   <= 1'b0           ;
                                    end
                                else if(scl_high)
                                    begin
                                        state       <= WR_START        ; 
                                        sda_reg     <= 1'b0            ;//起始位
                                    end 
                            end
                        WR_CTRL:
                            begin
                                if(data_busy == 1'b0)
                                    send_data_8bits;
                                else
                                    begin
                                        if(ack == 1'b1)
                                            begin
                                                if(scl_low)
                                                    begin
                                                        state     <= WR_WADDR;
                                                        data_busy <= 1'b0;
                                                            if(Wd_addr_long == 2'b1)
                                                                iic_sda_out <= Word_addr[ 7:0];
                                                            else
                                                                iic_sda_out <= Word_addr[15:8];
                                                    end
                                                else
                                                        state <= WR_CTRL;
                                            end 
                                        else
                                            state <= IDLE;
                                    end
                            end
                        WR_WADDR:
                            begin
                                if(data_busy == 1'b0)
                                    send_data_8bits;
                                else
                                    if(ack == 1'b1)
                                        begin
                                            if(Wd_addr_long == word_addr_cnt)
                                                begin
                                                if((wr_flag)&&(scl_low))
                                                begin
                                                    state         <= WR_DATA    ;
                                                    iic_sda_out   <= wr_data    ;
                                                    data_busy     <= 1'b0       ;
                                                    word_addr_cnt <= 2'b1       ;
                                                end
                                                else if((rd_flag)&&(scl_low))
                                                begin
                                                    state         <= RD_START   ;
                                                    sda_reg       <= 1'b1       ;
                                                end
                                                end
                                            else
                                                begin
                                                    if(scl_low)
                                                        state         <= WR_WADDR            ;
                                                        word_addr_cnt <= word_addr_cnt + 1'b1;
                                                        data_busy     <= 1'b0                ;
                                                        iic_sda_out   <= Word_addr[ 7:0]     ;                                                         
                                                end                                                
                                        end
                                    else
                                        state <= IDLE;
                            end
                        WR_DATA:
                            begin
                                if(data_busy == 1'b0)
                                    send_data_8bits;
                                else
                                    begin
                                        if(ack == 1'b1)
                                            begin
                                                if(wr_data_long == wr_data_cnt)
                                                    begin
                                                        if(scl_low)
                                                            begin
                                                                state     <= STOP;
                                                                data_busy <= 1'b1;
                                                                sda_reg   <= 1'b1;                                                
                                                            end
                                                        else
                                                            state <= WR_DATA;
                                                    end
                                                else
                                                    begin
                                                        if(scl_low)
                                                            begin
                                                            state        <= WR_DATA           ;
                                                            data_busy    <= 1'b0              ;
                                                            iic_sda_out  <= wr_data           ;
                                                            wr_data_cnt  <= wr_data_cnt + 1'b1; 
                                                            end
                                                        else
                                                            state <= WR_DATA;
                                                    end
                                            end
                                        else
                                            state <= IDLE;
                                    end
                            end
                        RD_START:
                            begin
                                if(scl_low)
                                    begin
                                        state        <= RD_CTRL        ;
                                        iic_sda_out  <= rd_control_sign;
                                        data_busy    <= 1'b0           ; 
                                    end
                                else if(scl_high)
                                    begin
                                        state   <= RD_START;
                                        sda_reg <= 1'b0;
                                    end
                                else
                                    state <= state;
                            end    
                        RD_CTRL:
                            begin
                                if(data_busy == 1'b0)
                                    send_data_8bits;
                                else
                                    begin
                                        if(ack == 1'b1)
                                            begin
                                                if(scl_low)
                                                    begin
                                                        state <= RD_DATA;
                                                        data_busy <= 1'b0;                                               
                                                    end
                                                else
                                                    state <= RD_CTRL;
                                            end
                                        else
                                            state <= IDLE; 
                                    end
                            end
                        RD_DATA:
                            begin
                                if(data_busy == 1'b0)
                                    receive_data_8bits;
                                else 
                                    begin
                                        if(rd_data_cnt == rd_data_long)
                                            begin
                                                sda_reg <= 1'b1;
                                                if(scl_low)
                                                    begin
                                                        state     <= STOP;
                                                        sda_reg   <= 1'b0;
                                                    end
                                                else
                                                    state <= RD_DATA;
                                            end
                                        else
                                            begin
                                                state       <= RD_DATA           ;
                                                data_busy   <= 1'b0              ;
                                                rd_data_cnt <= rd_data_cnt + 1'b1;
                                            end                                             
                                    end
                            end
                        STOP:
                            begin
                                if(scl_high)
                                    begin
                                        sda_reg       <= 1'b1;
                                        state         <= IDLE;
                                        iic_busy_done <= 1'b1;
                                    end
                                else
                                    state <= STOP;
                            end
                        default: 
                            begin
                                state   <= IDLE;
                            end
                    endcase
                end
        end

endmodule
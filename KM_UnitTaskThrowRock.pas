unit KM_UnitTaskThrowRock;
{$I KaM_Remake.inc}
interface
uses Classes, KM_CommonTypes, KM_Defaults, KM_Units, KromUtils, SysUtils;


{Throw a rock}
type
  TTaskThrowRock = class(TUnitTask)
    private
      fTarget:TKMUnit;
      fFlightTime:word; //Thats how long it will take a stone to hit it's target
    public
      constructor Create(aUnit,aTarget:TKMUnit);
      constructor Load(LoadStream:TKMemoryStream); override;
      procedure SyncLoad(); override;
      procedure Execute(out TaskDone:boolean); override;
      procedure Save(SaveStream:TKMemoryStream); override;
    end;


implementation
uses KM_PlayersCollection, KM_UnitActionWalkTo, KM_Game, KM_Utils, KM_Projectiles;


{ TTaskThrowRock }
constructor TTaskThrowRock.Create(aUnit,aTarget:TKMUnit);
begin
  Inherited Create(aUnit);
  fTaskName := utn_ThrowRock;
  fTarget := aTarget;
end;


constructor TTaskThrowRock.Load(LoadStream:TKMemoryStream);
begin
  Inherited;
  LoadStream.Read(fTarget, 4);
end;


procedure TTaskThrowRock.SyncLoad();
begin
  Inherited;
  fTarget := fPlayers.GetUnitByID(cardinal(fTarget));
end;


procedure TTaskThrowRock.Execute(out TaskDone:boolean);
begin
  TaskDone := false;

  if fUnit.GetHome.IsDestroyed then begin
    Abandon;
    TaskDone := true;
    exit;
  end;

  with fUnit do
  case fPhase of
    0: begin
         if not FREE_ROCK_THROWING then GetHome.ResTakeFromIn(rt_Stone, 1);
         GetHome.SetState(hst_Work); //Set house to Work state
         GetHome.fCurrentAction.SubActionWork(ha_Work2); //show Recruits back
         fFlightTime := fGame.fProjectiles.AddItem(fUnit.PositionF, fTarget.PositionF, pt_TowerRock);
         SetActionStay(5,ua_Walk); //take the stone
       end;
    1: begin
         GetHome.SetState(hst_Idle);
         SetActionStay(fFlightTime + 5,ua_Walk); //look how it goes
       end;
    else TaskDone := true;
  end;
  inc(fPhase);
  if (fUnit.GetUnitAction=nil)and(not TaskDone) then
    fGame.GameError(fUnit.GetPosition, 'ThrowRock No action, no TaskDone!');
end;


procedure TTaskThrowRock.Save(SaveStream:TKMemoryStream);
begin
  Inherited;
  if fTarget <> nil then
    SaveStream.Write(fTarget.ID) //Store ID, then substitute it with reference on SyncLoad
  else
    SaveStream.Write(Zero);
end;



end.
